/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

module micdn.www;
/// WWW 静态内容：构建时按 `<doc>` 挂载到 `www.base` 下同名路径，运行时 `base ~ httpPath` 直接读盘。

import std.algorithm;
import std.exception;
import std.file;
import std.path : absolutePath, baseName, buildPath, dirName, expandTilde;
import std.string;

import vibe.core.file;
import vibe.core.log;

import micdn.fs.file;
import micdn.model;
import micdn.npm;
import micdn.web.file;
import micdn.web;
import micdn.web.ext;

/// 按 doc endpoint 段组织的查找树：URI 段逐级匹配，返回最长前缀命中的 doc。
/// 不做规范化；调用方须保证传入段已规范化（如由 `resolveRepositoryPath` 归一后剥离 baseAbs 前缀）。
class WwwDocTree {
  private static final class Node {
    WwwDocConfig doc;
    Node[string] children;
  }

  private Node root_;

  this(const WwwDocConfig[] docs) {
    root_ = new Node();
    foreach (doc; docs)
      add(doc);
  }

  /** 将 doc 按 endpoint 段挂到树中（如 `manual/getting-started` → manual → getting-started）；endpoint 重复时抛异常。 */
  private void add(const(WwwDocConfig) doc) {
    auto node = root_;
    foreach (seg; segments(doc.endpoint())) {
      auto next = seg in node.children;
      if (next is null) {
        auto child = new Node();
        node.children[seg] = child;
        node = child;
      } else {
        node = *next;
      }
    }
    if (node.doc !is null)
      throw new Exception("duplicate www doc endpoint: " ~ doc.endpoint());
    node.doc = cast(WwwDocConfig) doc;
  }

  /** 逐级匹配；断链或遍历结束时返回最后挂 doc 的节点，无匹配返回 null。 */
  const(WwwDocConfig) find(scope const(string)[] segments) const {
    return findNode(root_, segments);
  }

  private static const(WwwDocConfig) findNode(const(Node) node, scope const(string)[] segments) {
    if (segments.length == 0)
      return node.doc;
    auto child = segments[0] in node.children;
    if (child is null)
      return node.doc;
    auto deeper = findNode(*child, segments[1 .. $]);
    return deeper !is null ? deeper : node.doc;
  }

  private static string[] segments(string endpoint) {
    string[] segs;
    foreach (part; endpoint.split("/")) {
      if (part.length > 0)
        segs ~= part;
    }
    return segs;
  }
}

/// `WwwRepo.get` 命中结果：最终文件路径、所属 doc 与命中文件的 `FileInfo`
/// （供 `sendFile` 复用，避免二次 stat）；未命中时 `path` 为 null（已匹配 doc 则 `doc` 非 null，便于 doc 粒度兜底）。
struct WwwFile {
  string path;
  const(WwwDocConfig) doc;
  FileInfo info;
}

/// `www.base` 下的统一仓库：磁盘布局与 URL 一致（`/manual/foo` → `{base}/manual/foo`）。
/// 仅服务已挂载 `<doc>` 下的路径；未挂 doc 的物理文件不对外提供。
class WwwRepo {
  /// `www.base` 根目录（绝对路径）
  const string base;
  const WwwDocConfig[] docs;

  private WwwDocTree docTree;

  this(string base, const WwwDocConfig[] docs = null) {
    enforce(base.length > 0, "repo base must not be empty");
    this.base = absolutePath(expandTilde(base));
    this.docs = docs;
    docTree = new WwwDocTree(docs);
  }

  static WwwRepo build(MicdnConfig config) {
    auto wwwBase = config.www.base;
    prepareBase(wwwBase);
    const(WwwDocConfig)[] docs;
    docs.reserve(config.www.docs.length);
    foreach (doc; config.www.docs) {
      deployDoc(config, doc);
      docs ~= servingDoc(wwwBase, doc);
    }
    return new WwwRepo(wwwBase, docs);
  }

  /** deploy 后校验 try-file 是否已落盘：缺失（`deployDoc` 已警告）则返回去除 try-file 的配置，
      运行期 `$uri`/`$uri/` 未命中时直接 404，不再回退到缺失的 try-file。 */
  private static const(WwwDocConfig) servingDoc(string wwwBase, const(WwwDocConfig) doc) {
    if (doc.tryFile.length == 0)
      return doc;
    auto path = resolveRepositoryPath(wwwBase, doc.endpoint() ~ "/" ~ doc.tryFile);
    if (path !is null && exists(path) && !std.file.isDir(path))
      return doc;
    return doc.withoutTryFile();
  }

  /** 按 HTTP 路径解析本地文件（须为 `getPath` 已解码路径；规范化并限制在 `base` 下）。
    先按 doc 树匹配：无 doc 返回 `WwwFile.init`（不读盘）。命中后顺序：$uri → $uri/（目录 index.html）→ 所属 doc 的 `try-file`（带静态扩展名且未命中则不回退）。
    返回语义：命中时 `path` 非空且 `info` 为命中文件的 stat 结果（供 `sendFile` 复用，避免二次 stat）；
    doc 匹配但文件缺失时 `path` 为 null 且 `doc` 保留（便于 doc 粒度兜底，如自定义 404）；无 doc 匹配时 `doc` 为 null。
  */
  WwwFile get(string uri) const {
    auto location = resolveRepositoryPath(base, uri);
    if (location is null)
      return WwwFile.init;

    auto doc = docTree.find(relativeSegments(base, location));
    if (doc is null)
      return WwwFile.init;

    // 单次异步 stat 区分文件/目录/缺失（不阻塞事件循环）；stat 与读盘之间文件可能变化，
    // 由 sendFile 的读盘失败兜底。目录折叠 index.html 与 try-file 回退各自再 stat 一次。
    try {
      auto fi = getFileInfo(location);
      if (fi.isDirectory) {
        auto indexPath = buildPath(location, "index.html");
        try {
          auto indexFi = getFileInfo(indexPath);
          if (indexFi.isFile)
            return WwwFile(indexPath, doc, indexFi);
        } catch (Exception) {
        }
        return WwwFile(null, doc);
      }
      if (fi.isFile)
        return WwwFile(location, doc, fi);
      // 特殊文件（fifo/socket 等）不对外服务
      return WwwFile(null, doc);
    } catch (Exception) {
      // location 缺失 → 按 doc 的 try-file 回退
    }

    if (doc.tryFile.length > 0) {
      if (isStaticAsset(uri))
        return WwwFile(null, doc);
      auto tryPath = resolveRepositoryPath(base, doc.endpoint() ~ "/" ~ doc.tryFile);
      if (tryPath !is null) {
        try {
          auto tryFi = getFileInfo(tryPath);
          if (tryFi.isFile)
            return WwwFile(tryPath, doc, tryFi);
        } catch (Exception) {
        }
      }
      return WwwFile(null, doc);
    }
    return WwwFile(null, doc);
  }

  /** 剥离 baseAbs 前缀并切段（路径已由 `resolveRepositoryPath` 归一，跳过空段）。 */
  private static string[] relativeSegments(string baseAbs, string path) {
    string[] segs;
    foreach (part; path[baseAbs.length .. $].split("/")) {
      if (part.length > 0)
        segs ~= part;
    }
    return segs;
  }

  /** 将单个 www `<doc>` 部署到 `www.base` 下与 `location` 同构的目录
    （如 `/manual` → `{base}/manual`）。供 `build` 与 `micdn … deploy www` 共用。

    按 provider 处理 npm 解压或 zip 增量解压。
    成功返回 true，失败打日志并返回 false。
  */
  static bool deployDoc(MicdnConfig config, const WwwDocConfig doc, bool force = false) {
    try {
      auto docDir = resolveRepositoryPath(config.www.base, doc.endpoint());
      assert(docDir !is null, "www doc path escapes base: " ~ doc.name);

      if (!verifyDeployDirWritable(docDir)) {
        logError("Deploy www %s failed: %s is not writable", doc.name, docDir);
        return false;
      }

      if (NpmProvider np = cast(NpmProvider) doc.provider) {
        if (!deployDocNpm(config, np, docDir, force))
          return false;
      } else if (ZipProvider zp = cast(ZipProvider) doc.provider) {
        if (!deployDocZip(zp, docDir, force))
          return false;
      } else {
        logError("Deploy www %s failed: unsupported provider (www only supports npm or zip)", doc.name);
        return false;
      }

      warnMissingTryFile(config.www.base, doc);
      return true;
    } catch (Exception e) {
      logError("Deploy www %s failed: %s", doc.name, e.msg);
      return false;
    }
  }

  /// deploy 完成后校验 `try-file` 是否已在磁盘上；缺失则警告（运行期由 sendFile 处理 404）。
  private static void warnMissingTryFile(string wwwBase, const WwwDocConfig doc) {
    if (doc.tryFile.length == 0)
      return;
    auto path = resolveRepositoryPath(wwwBase, doc.endpoint() ~ "/" ~ doc.tryFile);
    if (path is null)
      return;
    if (!exists(path) || std.file.isDir(path))
      logWarn("www doc %s try-file %s not found at %s", doc.name, doc.tryFile, path);
  }

  /// `<npm>`：拉取 tgz 并解压到 `docDir`。
  private static bool deployDocNpm(MicdnConfig config, const NpmProvider np, string docDir, bool force) {
    string scopePart, namePart, versionPart;
    parsePackageSpec(np.packageSpec, scopePart, namePart, versionPart);
    if (namePart.length == 0 || versionPart.length == 0) {
      logWarn("Invalid npm package spec: %s", np.packageSpec);
      return false;
    }
    auto npmRepo = NpmRepo.build(config);
    if (!npmRepo.fetch(scopePart, namePart, versionPart)) {
      logWarn("Cannot resolve npm package %s", np.packageSpec);
      return false;
    }
    auto tgzPath = npmRepo.localTarball(scopePart, namePart, versionPart);
    if (!extractTgzToDocBase(tgzPath, docDir, "package/" ~ np.dir, np.packageSpec, force)) {
      logWarn("Failed to extract %s to %s", tgzPath, docDir);
      return false;
    }
    return true;
  }

  /// `<zip>`：增量解压到 `docDir`。
  private static bool deployDocZip(const ZipProvider zp, string docDir, bool force) {
    if (refreshUnzip(zp.file, docDir, zp.dir, baseName(zp.file), force) == 0) {
      logWarn("Cannot find %s in %s", zp.dir, zp.file);
      return false;
    }
    return true;
  }

  /** 确保 `www.base` 存在且目录本身可写（见 `ensureDirWritable`，不递归子项）。 */
  static void prepareBase(string wwwBase) {
    mkdirRecurse(wwwBase);
    ensureDirWritable(wwwBase);
  }

}
