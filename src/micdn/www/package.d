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
import std.path : absolutePath, baseName, buildPath, dirName, expandTilde;
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

/// www 文件索引条目：发布期 stat 的轻量快照（路径由段树节点隐含，不重复存储）。
/// 仅保留 HTTP 服务所需字段：类型标志、大小与修改时间（ETag/Last-Modified/Content-Length）。
struct IndexedFileInfo {
  enum : ubyte { dirFlag = 0x01, fileFlag = 0x02, symlinkFlag = 0x04 }

  ulong size;
  long modified; // stdTime（UTC，2000-01-01 起 hnsecs）
  ubyte flags;

  /// 展开为 vibe `FileInfo`（name/directory 由给定物理路径切片派生，零分配）。
  FileInfo toFileInfo(string path) const @safe {
    FileInfo fi;
    fi.name = baseName(path);
    fi.directory = NativePath(dirName(path));
    fi.size = size;
    fi.timeModified = SysTime(modified, UTC());
    fi.isSymlink = (flags & symlinkFlag) != 0;
    fi.isDirectory = (flags & dirFlag) != 0;
    fi.isFile = (flags & fileFlag) != 0;
    return fi;
  }

  bool isDirectory() const @safe pure nothrow {
    return (flags & dirFlag) != 0;
  }

  bool isFile() const @safe pure nothrow {
    return (flags & fileFlag) != 0;
  }
}

/// 单 doc 的发布期文件索引：按相对 doc 根的段组织的树（段名共享，无路径冗余）。
/// 请求期沿段遍历判定存在性：命中叶子 = 存在，断链 = 缺失，全程 0 stat。
private final class WwwFileIndex {
  private static final class Node {
    IndexedFileInfo info;
    bool hasInfo;
    Node[string] children;
  }

  private Node root_;
  private size_t fileCount_;
  private size_t dirCount_;
  private size_t symlinkCount_;

  /// 遍历 docDir 构建（发布期一次；autodeploy 后重建）。
  this(string docDir) {
    root_ = buildDir(docDir, fileCount_, dirCount_, symlinkCount_);
  }

  /// 索引内文件数（不含被跳过的 `*.gz` sidecar）。
  size_t fileCount() const @property { return fileCount_; }
  /// 索引内目录数（含 doc 根）。
  size_t dirCount() const @property { return dirCount_; }
  /// 索引内符号链接数（只计数，不建条目；请求期按缺失处理）。
  size_t symlinkCount() const @property { return symlinkCount_; }

  /// 按相对 doc 根段查：命中（文件或目录）返回 info 引用；断链返回 null。
  const(IndexedFileInfo)* find(scope const(string)[] segments) const {
    auto node = &root_;
    foreach (seg; segments) {
      auto next = seg in node.children;
      if (next is null)
        return null;
      node = next;
    }
    return node.hasInfo ? &node.info : null;
  }

  private static Node buildDir(string dir, ref size_t files, ref size_t dirs, ref size_t symlinks) {
    auto node = new Node();
    node.hasInfo = true;
    node.info.flags = IndexedFileInfo.dirFlag;
    node.info.modified = DirEntry(dir).timeLastModified.stdTime;
    dirs++;
    foreach (entry; dirEntries(dir, SpanMode.shallow)) {
      auto name = baseName(entry.name);
      // 跳过运行期 sidecar `*.gz`：非部署内容，且 gz 服务由 web 层直接 `getFileInfo` 现查，
      // 不依赖索引；排除后反复启停也不会把遗留 gz 的元数据预扫进 page cache。
      if (entry.isFile && name.endsWith(".gz"))
        continue;
      if (entry.isDir) {
        node.children[name] = buildDir(entry.name, files, dirs, symlinks);
      } else if (entry.isFile) {
        files++;
        auto child = new Node();
        child.hasInfo = true;
        child.info.flags = IndexedFileInfo.fileFlag;
        child.info.size = entry.size;
        child.info.modified = entry.timeLastModified.stdTime;
        node.children[name] = child;
      } else {
        symlinks++;
      }
    }
    return node;
  }
}

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
  private WwwFileIndex[string] docIndexes;

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
    auto repo = new WwwRepo(wwwBase, docs);
    repo.buildIndexes();
    return repo;
  }

  /** 为全部 doc 构建发布期文件索引（deploy 完成后调用，启动期一次目录遍历）。 */
  private void buildIndexes() {
    foreach (doc; docs)
      buildDocIndex(doc);
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

  /** 构建单个 doc 的发布期索引并输出汇总日志（文件/目录/符号链接数与构建耗时）。 */
  private void buildDocIndex(const(WwwDocConfig) doc) {
    auto docDir = resolveRepositoryPath(base, doc.endpoint());
    if (docDir is null)
      return;
    auto sw = StopWatch(AutoStart.yes);
    auto idx = new WwwFileIndex(docDir);
    docIndexes[doc.name] = idx;
    logInfo("Built www file index for doc '%s': %s files, %s dirs, %s symlinks in %s ms",
        doc.name, idx.fileCount, idx.dirCount, idx.symlinkCount, sw.peek.total!"msecs");
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

    auto segs = relativeSegments(base, location);
    auto doc = docTree.find(segs);
    if (doc is null)
      return WwwFile.init;

  // 发布期索引路径：存在性/目录折叠/try-file 回退全部查表，0 stat；
  // 断链即 404（索引由 deploy 构建并在 autodeploy 后重建，与磁盘保持一致）。
  if (auto p = doc.name in docIndexes) {
    auto rs = resolveFromIndex(doc, *p, uri, location, segs);
    if (rs.path !is null)
      return rs;
    return WwwFile(null, doc);
  }

  // 无索引 doc（如直接 `new WwwRepo` 构造）走 stat 兜底解析。
  return resolveByStat(doc, uri, location);
}

/** 无索引 doc 的兜底解析：异步 stat 区分文件/目录/缺失，目录折叠 index.html，断链按 try-file 回退。
    stat 与读盘之间文件可能变化，由 sendFile 的读盘失败兜底。目录折叠 index.html 与 try-file 回退各自再 stat 一次。 */
private WwwFile resolveByStat(const(WwwDocConfig) doc, string uri, string location) const {
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

  /** 沿发布期索引解析相对 doc 根的段：命中文件或目录折叠 index.html 直接返回；
      SPA try-file 回退同样查索引（0 stat）；断链返回 null（调用方转 404）。 */
  private WwwFile resolveFromIndex(const(WwwDocConfig) doc, ref const(WwwFileIndex) idx,
      string uri, string location, scope const(string)[] rel) const {
    auto docSegs = doc.segments;
    auto fileSegs = rel[docSegs.length .. $];

    if (fileSegs.length == 0) {
      // doc 根（`/manual` 或 `/manual/`）：折叠 index.html
      auto ih = idx.find(["index.html"]);
      if (ih !is null && ih.isFile) {
        auto indexPath = buildPath(location, "index.html");
        return WwwFile(indexPath, doc, ih.toFileInfo(indexPath));
      }
      return WwwFile(null, doc);
    }

    auto hit = idx.find(fileSegs);
    if (hit !is null) {
      if (hit.isDirectory) {
        auto ih = idx.find(fileSegs ~ ["index.html"]);
        if (ih !is null && ih.isFile) {
          auto indexPath = buildPath(location, "index.html");
          return WwwFile(indexPath, doc, ih.toFileInfo(indexPath));
        }
        return WwwFile(null, doc);
      }
      return WwwFile(location, doc, hit.toFileInfo(location));
    }

    // 断链：SPA try-file 回退（索引内查找，0 stat）；带静态扩展名不参与回退。
    if (doc.tryFile.length > 0) {
      if (isStaticAsset(uri))
        return WwwFile(null, doc);
      auto th = idx.find([doc.tryFile]);
      if (th !is null && th.isFile) {
        auto tryPath = resolveRepositoryPath(base, doc.endpoint() ~ "/" ~ doc.tryFile);
        if (tryPath !is null)
          return WwwFile(tryPath, doc, th.toFileInfo(tryPath));
      }
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
