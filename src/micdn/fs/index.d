/* Copyright (C) 2026 Beangle
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

module micdn.fs.index;
/// 目录文件索引：发布期对目录做一次遍历建表，请求期沿段树判定存在性，全程 0 stat。
/// 供 www doc、asset bundle 等静态仓库复用；同一趟构建把 `path.gz` sidecar 的**大小**
/// 直接存到源文件的 `IndexedFileInfo.gzSize` 上（`.gz` 不建独立节点），请求期一次 `find`
/// 同时取得源文件与预压缩信息。sidecar 的 `modified`/`flags` 语义上复用源文件（gz 是源文件的编码表示）。

import std.datetime : SysTime, UTC;
import std.algorithm : endsWith;
import std.conv : to;
import std.file;
import std.path : baseName, dirName;

import vibe.core.file;
import vibe.core.path;

/// 索引汇总日志的 symlink 段：数量为 0 时省略（不输出无意义的 "0 symlinks"），大于 0 时输出 ", N symlinks"。
string symlinkSummaryPart(size_t symlinkCount) {
  return symlinkCount > 0 ? ", " ~ symlinkCount.to!string ~ " symlinks" : "";
}

/// 文件索引条目：发布期 stat 的轻量快照（路径由段树节点隐含，不重复存储）。
/// 仅保留 HTTP 服务所需字段：类型标志、大小、修改时间（ETag/Last-Modified/Content-Length）
/// 与同目录 `path.gz` sidecar 的大小（`gzSize`，仅文件节点有意义；0 = 无）。
struct IndexedFileInfo {
  enum : ubyte { dirFlag = 0x01, fileFlag = 0x02, symlinkFlag = 0x04 }

  ulong size;
  ulong gzSize; // 同目录 `name.gz` sidecar 的大小（0 = 无；modified/flags 复用源文件）
  long modified; // stdTime（UTC，2000-01-01 起 hnsecs）
  ubyte flags;

  /// 由 vibe `FileInfo` 转换（非索引调用方：blob/npm/maven、asset `<dir>`、www stat 兜底；`gzSize` 保持 0）。
  static IndexedFileInfo fromFileInfo(const FileInfo fi) @safe {
    IndexedFileInfo info;
    info.size = fi.size;
    info.modified = fi.timeModified.stdTime;
    if (fi.isDirectory)
      info.flags |= dirFlag;
    if (fi.isFile)
      info.flags |= fileFlag;
    if (fi.isSymlink)
      info.flags |= symlinkFlag;
    return info;
  }

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

/// 单根目录的发布期文件索引：按相对根目录的段组织的树（段名共享，无路径冗余）。
/// 请求期沿段遍历判定存在性：命中叶子 = 存在，断链 = 缺失，全程 0 stat。
final class FileIndex {
  /// 索引根目录（绝对路径）；构造传入，命中时直接拼物理路径，避免请求期重建
  const string rootDir;

  private static final class Node {
    IndexedFileInfo info;
    Node[string] children;
  }

  private Node root_;
  private size_t fileCount_;
  private size_t dirCount_;
  private size_t symlinkCount_;

  /// 遍历 rootDir 构建（发布期一次；重新部署后重建）。
  /// 构建为纯只读目录扫描：不生成、不修改任何文件（`*.gz` sidecar 由部署期 `precompressDir`
  /// 预生成后，本扫描仅登记其大小；运行期重建索引同样不会触发 gz 生成）。
  this(string rootDir) {
    this.rootDir = rootDir;
    root_ = buildDir(rootDir, fileCount_, dirCount_, symlinkCount_);
  }

  /// 索引内文件数（不含 sidecar `*.gz`）。
  size_t fileCount() const @property { return fileCount_; }
  /// 索引内目录数（含根目录）。
  size_t dirCount() const @property { return dirCount_; }
  /// 索引内符号链接数（只计数，不建条目；请求期按缺失处理）。
  size_t symlinkCount() const @property { return symlinkCount_; }

  /// 按相对根目录段查：命中（文件或目录）返回条目（含 `gzSize`）；断链返回 null。
  const(IndexedFileInfo)* find(scope const(string)[] segments) const {
    auto node = &root_;
    foreach (seg; segments) {
      auto next = seg in node.children;
      if (next is null)
        return null;
      node = next;
    }
    return &node.info;
  }

  private static Node buildDir(string dir, ref size_t files, ref size_t dirs, ref size_t symlinks) {
    auto node = new Node();
    node.info.flags = IndexedFileInfo.dirFlag;
    node.info.modified = DirEntry(dir).timeLastModified.stdTime;
    dirs++;

    // 第一趟收集浅层条目：目录递归建节点；`.gz` 仅登记大小、不建节点（绝不当原文件索引，
    // 孤儿 `.gz` 无挂载点自然丢弃），其余文件登记信息。
    IndexedFileInfo[string] fileInfos;
    ulong[string] gzSizes;
    foreach (entry; dirEntries(dir, SpanMode.shallow)) {
      auto name = baseName(entry.name);
      if (entry.isDir) {
        node.children[name] = buildDir(entry.name, files, dirs, symlinks);
      } else if (entry.isFile) {
        if (name.endsWith(".gz"))
          gzSizes[name] = entry.size;
        else {
          IndexedFileInfo info;
          info.flags = IndexedFileInfo.fileFlag;
          info.size = entry.size;
          info.modified = entry.timeLastModified.stdTime;
          files++;
          fileInfos[name] = info;
        }
      } else {
        symlinks++;
      }
    }
    // 第二趟（同一构建阶段）：源文件节点直接携带同目录 `name.gz` 的 sidecar 大小。
    foreach (name, info; fileInfos) {
      auto child = new Node();
      child.info = info;
      if (auto gz = (name ~ ".gz") in gzSizes)
        child.info.gzSize = *gz;
      node.children[name] = child;
    }
    return node;
  }
}
