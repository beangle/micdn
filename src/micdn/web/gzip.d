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

module micdn.web.gzip;
/// gzip 预压缩 sidecar：部署期预压缩与请求侧资格判断。
///
/// 设计约定：
/// - 压缩只发生在部署期（www doc `auto-gzip` 时、asset 非 `<dir>` bundle），写 `tmp` 后原子 `rename`，无请求期竞争。
/// - 请求线程只读：调用方预取 `path.gz` 的**大小**（www 发布期索引、asset 非 `<dir>` 索引均含 `gzSize`），
///   由 `web.file.sendFile` 按 `gzSize` 决定是否发送；不再有后台压缩线程。
/// - asset 的 `<dir>` 符号链接挂载完全忽略 gzip（不发送已有 `.gz` 也不生成），由调用方以 `gzSize=0` 排除。

import std.file;
import std.path;
import std.string;
import std.uni : toLower;
import std.zlib : Compress, HeaderFormat;

import vibe.http.server : HTTPServerRequest;

/// 单个文件小于该大小不压缩（gzip 固定开销约 18 字节，小文本压缩后通常不更小，避免无收益生成）。
enum size_t minGzipFileSize = 1024;
/// 单个文件超过该大小不压缩（避免大内存分配），与 `web.file` 内存发送阈值一致。
enum size_t maxGzipFileSize = 8u * 1024 * 1024;
/// 压缩级别：部署期执行，用最高级别。
enum int gzipCompressionLevel = 9;

/// 可压缩的文本类扩展名（小写、含前导 `.`）。已压缩格式（`.gz`/`.br`/图片/字体等）不在白名单。
immutable string[] gzipExtensionList = [
    ".js", ".mjs", ".cjs", ".css", ".html", ".htm", ".svg",
    ".json", ".map", ".xml", ".txt", ".md", ".webmanifest",
];

/// 扩展名 O(1) 查询。
immutable bool[string] gzipExtensions;

shared static this() {
  bool[string] set;
  foreach (ext; gzipExtensionList)
    set[ext] = true;
  gzipExtensions = cast(immutable) set;
}

/** 文件是否适合 gzip（扩展名在白名单内，且不是符号链接由调用方保证）。 */
bool isGzipEligible(string path) @safe pure {
  auto ext = std.path.extension(std.path.baseName(path)).toLower();
  return (ext in gzipExtensions) !is null;
}

/** 文件大小是否在可压缩范围内（`minGzipFileSize <= size <= maxGzipFileSize`）。 */
bool isGzipSized(ulong size) @safe pure nothrow {
  return size >= minGzipFileSize && size <= maxGzipFileSize;
}

/** 文件整体是否适合压缩：非符号链接、扩展名白名单、大小在区间内。
    存在性/目录检查由调用方前置完成（如 `gzipFile` 已检查）。
*/
bool isGzipEligibleFile(string path) @safe {
  if (isSymlink(path))
    return false;
  if (!isGzipEligible(path))
    return false;
  return isGzipSized(getSize(path));
}

/** 请求头 `Accept-Encoding` 是否接受 gzip。

    面向现代浏览器的简化实现：仅按子串识别 `gzip`（大小写不敏感），
    不处理 `q=0` 拒绝与 `*` 通配等完备语义（这些在现代客户端中几乎不出现）。
    未携带 `Accept-Encoding` 时不视为接受 gzip。
*/
bool acceptsGzip(scope HTTPServerRequest req) @safe {
  auto ae = "Accept-Encoding" in req.headers;
  if (ae is null)
    return false;
  return (*ae).toLower().indexOf("gzip") >= 0;
}

/** 将单个文件压缩为 `path.gz`（tmp + rename 原子落盘）。

    仅当压缩后确实更小才生成；文件不存在、过大、已是符号链接或不可压缩时返回 false。
    sidecar 已存在时视为成功（幂等，供部署期对同一目录的重复调用）。
*/
bool gzipFile(string path) {
  if (!exists(path) || isDir(path))
    return false;
  if (!isGzipEligibleFile(path))
    return false;
  auto gzPath = path ~ ".gz";
  if (exists(gzPath))
    return true;

  auto data = read(path);
  auto comp = new Compress(gzipCompressionLevel, HeaderFormat.gzip);
  ubyte[] gzData;
  gzData ~= cast(ubyte[]) comp.compress(data);
  gzData ~= cast(ubyte[]) comp.flush();
  if (gzData.length >= data.length)
    return false;

  auto tmpPath = gzPath ~ ".tmp";
  scope (failure) {
    if (exists(tmpPath))
      remove(tmpPath);
  }
  std.file.write(tmpPath, gzData);
  rename(tmpPath, gzPath);
  return true;
}

/** 遍历目录，为每个可压缩且大小在区间内的普通文件生成 `path.gz`（sidecar 已存在则跳过）。
    供部署期调用（www doc `auto-gzip`、asset 非 `<dir>` bundle）；返回本次生成的 sidecar 数。 */
size_t precompressDir(string dir) {
  size_t n;
  foreach (entry; dirEntries(dir, SpanMode.depth)) {
    if (entry.isFile && !exists(entry.name ~ ".gz") && gzipFile(entry.name))
      n++;
  }
  return n;
}
