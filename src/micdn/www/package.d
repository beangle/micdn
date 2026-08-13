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
import std.datetime : SysTime, UTC;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.exception;
import std.file;
import std.path : baseName, buildPath;
import std.string;

import vibe.core.file;
import vibe.core.log;
import vibe.core.path;

import micdn.fs.file;
import micdn.model;
import micdn.npm;
import micdn.web.file;
import micdn.web;
import micdn.web.ext;
import micdn.fs.index;
import micdn.web.gzip;

/// 按 doc endpoint 段组织的查找树：URI 段逐级匹配，返回最长前缀命中的 doc。
/// 不做规范化；调用方须保证传入段已由 `getResourceUri` 切段消解。
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
    foreach (seg; doc.segments) {
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
}

/// `WwwRepo.get` 命中结果：最终文件路径、所属 doc 与命中文件的 `IndexedFileInfo`
/// （供 `sendFile` 复用，避免二次 stat）；`autoGzip` 且 sidecar 存在时 `info.gzSize` 为 `path.gz` 的大小
/// （0 = 无；`modified`/`flags` 复用源文件）。
/// 未命中时 `path` 为 null（已匹配 doc 则 `doc` 非 null，便于 doc 粒度兜底）。
struct WwwFile {
  string path;
  const(WwwDocConfig) doc;
  IndexedFileInfo info;
}

/// `www.base` 下的统一仓库：磁盘布局与 URL 一致（`/manual/foo` → `{base}/manual/foo`）。
/// 仅服务已挂载 `<doc>` 下的路径；未挂 doc 的物理文件不对外提供。
class WwwRepo {
  /// `www.base` 根目录（绝对路径）
  const string base;
  const WwwDocConfig[] docs;

  private WwwDocTree docTree;
  private FileIndex[string] docIndexes;

  this(string base, const WwwDocConfig[] docs = null) {
    enforce(base.length > 0, "repo base must not be empty");
    this.base = normalizeBasePath(base);
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
    auto repo = new WwwRepo(wwwBase, docs);
    repo.buildIndexes();
    return repo;
  }

  /** 为全部 doc 构建发布期文件索引并输出**汇总**日志（deploy 完成后调用，启动期一次目录遍历）。 */
  private void buildIndexes() {
    size_t docCount, fileCount, dirCount, symlinkCount;
    auto sw = StopWatch(AutoStart.yes);
    foreach (doc; docs) {
      auto docDir = buildPath(base, doc.name);
      auto idx = new FileIndex(docDir);
      docIndexes[doc.name] = idx;
      docCount++;
      fileCount += idx.fileCount;
      dirCount += idx.dirCount;
      symlinkCount += idx.symlinkCount;
    }
    logInfo("Built www file indexes: %s docs, %s files, %s dirs%s in %s ms",
        docCount, fileCount, dirCount, symlinkSummaryPart(symlinkCount), sw.peek.total!"msecs");
  }

  /// autodeploy 重新部署某 doc 后重建其索引（供 `WwwAutoDeployer` 调用）。
  void rebuildIndex(string docName) {
    foreach (doc; docs) {
      if (doc.name != docName)
        continue;
      buildDocIndex(doc);
      return;
    }
  }

  /** 构建单个 doc 的发布期索引（autodeploy 重建后调用；启动期全量构建见 `buildIndexes` 的汇总日志）。 */
  private void buildDocIndex(const(WwwDocConfig) doc) {
    auto docDir = buildPath(base, doc.name);
    auto sw = StopWatch(AutoStart.yes);
    auto idx = new FileIndex(docDir);
    docIndexes[doc.name] = idx;
    logInfo("Rebuilt www file index for doc '%s': %s files, %s dirs%s in %s ms",
        doc.name, idx.fileCount, idx.dirCount, symlinkSummaryPart(idx.symlinkCount), sw.peek.total!"msecs");
  }

  /** deploy 后校验 try-file 是否已落盘：缺失（`deployDoc` 已警告）则返回去除 try-file 的配置，
      运行期 `$uri`/`$uri/` 未命中时直接 404，不再回退到缺失的 try-file。 */
  private static const(WwwDocConfig) servingDoc(string wwwBase, const(WwwDocConfig) doc) {
    if (doc.tryFile.length == 0)
      return doc;
    auto path = buildPath(wwwBase, doc.name, doc.tryFile);
    if (exists(path) && !std.file.isDir(path))
      return doc;
    return doc.withoutTryFile();
  }

  /** 便捷值重载：rvalue（如测试直构）走浅拷贝；生产路径（web 层持 lvalue）走 `ref` 版本。 */
  WwwFile get(const ResourceUri uri) const {
    return get(uri);
  }

  /** 按入口解析出的仓库 URI 解析本地文件（仅供 web 服务层调用；**调用方负责防穿越**：须已由 `getResourceUri`
      切段消解，未消解的点段（`.`/`..`）可能导致 stat 兜底越界，属调用方违约）。
    doc 树匹配与路径构造全部基于规范化段：命中文件路径 = `buildPath(base, uri.segs)`，无 `..` 段，天然限制在 `base` 下。
    先按 doc 树匹配：无 doc 返回 `WwwFile.init`（不读盘）。命中后顺序：$uri → $uri/（目录 index.html）→ 所属 doc 的 `try-file`（带静态扩展名且未命中则不回退）。
    返回语义：命中时 `path` 非空且 `info` 为命中文件的 stat 结果（供 `sendFile` 复用，避免二次 stat）；
    doc 匹配但文件缺失时 `path` 为 null 且 `doc` 保留（便于 doc 粒度兜底，如自定义 404）；无 doc 匹配时 `doc` 为 null。
  */
  WwwFile get(ref const(ResourceUri) uri) const {
    auto doc = docTree.find(uri.segs);
    if (doc is null)
      return WwwFile.init;

  // 发布期索引路径：存在性/目录折叠/try-file 回退全部查表，0 stat；
  // 断链即 404（索引由 deploy 构建并在 autodeploy 后重建，与磁盘保持一致）。
  if (auto p = doc.name in docIndexes) {
    auto rs = resolveFromIndex(doc, *p, uri);
    if (rs.path !is null)
      return rs;
    return WwwFile(null, doc);
  }

  // 无索引 doc（如直接 `new WwwRepo` 构造）走 stat 兜底解析。
  return resolveByStat(doc, uri);
}

  /** 无索引 doc 的兜底解析：异步 stat 区分文件/目录/缺失，目录折叠 index.html，断链按 try-file 回退。
      stat 与读盘之间文件可能变化，由 sendFile 的读盘失败兜底。目录折叠 index.html 与 try-file 回退各自再 stat 一次。 */
  private WwwFile resolveByStat(const(WwwDocConfig) doc, ref const(ResourceUri) uri) const {
    auto docSegs = doc.segments;
    auto fileSegs = uri.segs[docSegs.length .. $];
    auto docDir = base ~ "/" ~ doc.name;
    auto location = repositoryPath(base, uri);
    try {
      auto fi = getFileInfo(location);
      if (fi.isDirectory) {
        auto indexPath = location ~ "/index.html";
        try {
          auto indexFi = getFileInfo(indexPath);
          if (indexFi.isFile)
            return attachGzByStat(doc, WwwFile(indexPath, doc, IndexedFileInfo.fromFileInfo(indexFi)));
        } catch (Exception) {
        }
        return WwwFile(null, doc);
      }
      if (fi.isFile)
        return attachGzByStat(doc, WwwFile(location, doc, IndexedFileInfo.fromFileInfo(fi)));
      // 特殊文件（fifo/socket 等）不对外服务
      return WwwFile(null, doc);
    } catch (Exception) {
      // location 缺失 → 按 doc 的 try-file 回退
    }

  if (doc.tryFile.length > 0) {
    if (fileSegs.length > 0 && isStaticAsset(fileSegs[$ - 1]))
      return WwwFile(null, doc);
    auto tryPath = docDir ~ "/" ~ doc.tryFile;
    try {
      auto tryFi = getFileInfo(tryPath);
      if (tryFi.isFile)
        return attachGzByStat(doc, WwwFile(tryPath, doc, IndexedFileInfo.fromFileInfo(tryFi)));
    } catch (Exception) {
    }
    return WwwFile(null, doc);
  }
  return WwwFile(null, doc);
}

/** stat 兜底路径附加 sidecar：doc 启用 autoGzip 时探测 `path.gz` 大小（非索引仓库，请求期一次异步 stat）。 */
private WwwFile attachGzByStat(const(WwwDocConfig) doc, WwwFile wf) const {
  if (!doc.autoGzip || wf.path.length == 0)
    return wf;
  try {
    auto gz = getFileInfo(wf.path ~ ".gz");
    if (gz.isFile)
      wf.info.gzSize = gz.size;
  } catch (Exception) {
  }
  return wf;
}

  /** 沿发布期索引解析相对 doc 根的段：命中文件或目录折叠 index.html 直接返回；
      SPA try-file 回退同样查索引（0 stat）；断链返回 null（调用方转 404）。 */
  private WwwFile resolveFromIndex(const(WwwDocConfig) doc, ref const(FileIndex) idx,
      ref const(ResourceUri) uri) const {
    auto docSegs = doc.segments;
    auto fileSegs = uri.segs[docSegs.length .. $];
    // 物理路径直接用索引根目录拼接（docDir 固定，构造时已归一；比每请求 buildPath 便宜）
    auto docDir = idx.rootDir;

    if (fileSegs.length == 0) {
      // doc 根（`/manual` 或 `/manual/`）：折叠 index.html
      auto ih = idx.find(["index.html"]);
      if (ih !is null && ih.isFile) {
        auto indexPath = docDir ~ "/index.html";
        return makeWwwFile(doc, ih, indexPath);
      }
      return WwwFile(null, doc);
    }

    auto hit = idx.find(fileSegs);
    if (hit !is null) {
      if (hit.isDirectory) {
        auto ih = idx.find(fileSegs ~ ["index.html"]);
        if (ih !is null && ih.isFile) {
          auto indexPath = docDir ~ "/" ~ fileSegs.join("/") ~ "/index.html";
          return makeWwwFile(doc, ih, indexPath);
        }
        return WwwFile(null, doc);
      }
      return makeWwwFile(doc, hit, docDir ~ "/" ~ fileSegs.join("/"));
    }

    // 断链：SPA try-file 回退（索引内查找，0 stat）；带静态扩展名不参与回退。
    if (doc.tryFile.length > 0) {
      if (isStaticAsset(fileSegs[$ - 1]))
        return WwwFile(null, doc);
      auto th = idx.find([doc.tryFile]);
      if (th !is null && th.isFile) {
        return makeWwwFile(doc, th, docDir ~ "/" ~ doc.tryFile);
      }
    }
    return WwwFile(null, doc);
  }

  /** 由索引命中构造 `WwwFile`：直接携带索引条目（含 `gzSize`，0 stat）；`auto-gzip=false` 时清零 sidecar。 */
  private WwwFile makeWwwFile(const(WwwDocConfig) doc, const(IndexedFileInfo)* hit, string path) const {
    WwwFile wf = WwwFile(path, doc, *hit);
    if (!doc.autoGzip)
      wf.info.gzSize = 0;
    return wf;
  }

  /** 将单个 www `<doc>` 部署到 `www.base` 下与 `location` 同构的目录
    （如 `/manual` → `{base}/manual`）。供 `build` 与 `micdn … deploy www` 共用。

    按 provider 处理 npm 解压或 zip 增量解压。
    成功返回 true，失败打日志并返回 false。
  */
  static bool deployDoc(MicdnConfig config, const WwwDocConfig doc, bool force = false) {
    try {
      auto docDir = buildPath(config.www.base, doc.name);

      if (!verifyDeployDirWritable(docDir)) {
        logError("Deploy www %s failed: %s is not writable", doc.name, docDir);
        return false;
      }

      bool deployed;
      if (NpmProvider np = cast(NpmProvider) doc.provider) {
        if (!deployDocNpm(config, np, docDir, force, deployed))
          return false;
      } else if (ZipProvider zp = cast(ZipProvider) doc.provider) {
        if (!deployDocZip(zp, docDir, force, deployed))
          return false;
      } else {
        logError("Deploy www %s failed: unsupported provider (www only supports npm or zip)", doc.name);
        return false;
      }

      // autoGzip：预压缩是实际解压部署的一环，manifest 快路径跳过解压时同样跳过（避免重复扫描）。
      if (doc.autoGzip && deployed)
        precompressDir(docDir);
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
    auto path = buildPath(wwwBase, doc.name, doc.tryFile);
    if (!exists(path) || std.file.isDir(path))
      logWarn("www doc %s try-file %s not found at %s", doc.name, doc.tryFile, path);
  }

  /// `<npm>`：拉取 tgz 并解压到 `docDir`；`deployed` 指示是否实际解压（manifest 快路径跳过时为 false）。
  private static bool deployDocNpm(MicdnConfig config, const NpmProvider np, string docDir, bool force,
      out bool deployed) {
    deployed = false;
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
    deployed = force || !canSkipDeploy(tgzPath, docDir, "package/" ~ np.dir, np.packageSpec);
    if (!extractTgzToDocBase(tgzPath, docDir, "package/" ~ np.dir, np.packageSpec, force)) {
      logWarn("Failed to extract %s to %s", tgzPath, docDir);
      return false;
    }
    return true;
  }

  /// `<zip>`：增量解压到 `docDir`；`deployed` 指示是否实际解压（manifest 快路径跳过时为 false）。
  private static bool deployDocZip(const ZipProvider zp, string docDir, bool force, out bool deployed) {
    deployed = force || !canSkipDeploy(zp.file, docDir, zp.dir, baseName(zp.file));
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
