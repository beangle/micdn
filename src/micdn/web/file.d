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

module micdn.web.file;
/// 静态文件响应与 Range/缓存控制等 HTTP 输出工具。

import std.algorithm;
import std.ascii : isWhite;
import std.conv;
import std.datetime;
import std.exception;
import std.stdio;
import std.string;
import std.typecons;

import vibe.core.file;
import vibe.core.path;
import vibe.core.stream;
import vibe.stream.memory : createMemoryStream;

/// 无 Range 时整文件若不超过此大小则读入内存再写出，避免 `FileStream` 与 `bodyWriter` 组合在部分场景下的句柄/GC 告警。
private enum maxWholeFileMemSend = 8u * 1024 * 1024;
import vibe.http.fileserver;
import vibe.http.server;
import vibe.inet.message;
import vibe.inet.mimetypes;

import micdn.web.gzip;
import micdn.fs.index;
import micdn.model;
import micdn.web.cache;

/// 在写出响应体之前调用（如 CORS、`Content-Disposition`）；与缓存头无关。
alias SendFileHook = void delegate(scope HTTPServerRequest req, scope HTTPServerResponse res);

string encodeAttachmentName(string name) @safe {
  import std.array;
  import vibe.textfilter.urlencode;

  auto filename = name.urlEncode();
  auto n = `attachment; filename="{filename}"; filename*=utf-8''{filename}`;
  return n.replace("{filename}", filename);
}

/**
 * Fetch url and store at local.
 * Downloads to a temp file in the same directory as target first (avoiding cross-device
 * rename), then renames on success. No target directory is created when download fails.
 *
 * 每次调用在 micdn 日志中固定打一条：成功 `Downloaded …`，失败 `Download failed …`（curl stderr 写入同条）。
 */
bool curlDownload(string url, string local) {
  import std.process : execute;
  import std.file, std.path, std.conv, std.datetime, std.string;
  import std.datetime.stopwatch : StopWatch, AutoStart;
  import vibe.core.log;

  mkdirRecurse(dirName(local));
  auto tmpPath = dirName(local) ~ "/." ~ baseName(local) ~ ".part";
  scope (exit) {
    if (exists(tmpPath))
      remove(tmpPath);
  }

  auto sw = StopWatch(AutoStart.yes);
  auto cmd = execute(["curl", "--fail", "--silent", "--show-error", "-L",
      "--connect-timeout", "10",
      "--max-time", "300",
      "--speed-time", "30",
      "--speed-limit", "1024",
      "-o", tmpPath, url]);
  sw.stop();

  if (cmd.status != 0) {
    auto detail = cmd.output.strip();
    if (detail.length)
      logWarn("Download failed %s -> %s (curl exit %s): %s", url, local, cmd.status, detail);
    else
      logWarn("Download failed %s -> %s (curl exit %s)", url, local, cmd.status);
    return false;
  }
  if (!exists(tmpPath)) {
    logWarn("Download failed %s -> %s: temp file missing after curl", url, local);
    return false;
  }
  rename(tmpPath, local);
  logInfo("Downloaded %s -> %s (%s bytes, %.1fs)", url, local, getSize(local),
      sw.peek.total!"seconds");
  return true;
}

/**
 * https://tools.ietf.org/html/rfc7233
 * Range can be in form "-\d", "\d-" or "\d-\d"
 */
ulong[2] parseRange(string range, ulong maxSize) @safe {
  if (range.canFind(','))
    throw new HTTPStatusException(HTTPStatus.notImplemented);
  if (maxSize == 0)
    throw new HTTPStatusException(cast(HTTPStatus) 416);
  auto s = range.split("-");
  if (s.length != 2)
    throw new HTTPStatusException(HTTPStatus.badRequest);
  ulong start = 0;
  ulong end = 0;
  try {
    if (s[0].length) {
      start = s[0].to!ulong;
      end = s[1].length ? s[1].to!ulong : (maxSize - 1);
    } else if (s[1].length) {
      end = (maxSize - 1);
      auto len = s[1].to!ulong;
      if (len >= end)
        start = 0;
      else
        start = end - len + 1;
    } else {
      throw new HTTPStatusException(HTTPStatus.badRequest);
    }
  } catch (ConvException) {
    throw new HTTPStatusException(HTTPStatus.badRequest);
  }
  if (end >= maxSize)
    end = maxSize - 1;
  if (start > end)
    start = end;
  return [start, end];
}

/** 发送单个文件；`policy` 必选，见 `micdn.web.cache`。
    `info` 必填且紧随 `path`：调用方预取的 `IndexedFileInfo`（www 发布期索引 / asset 索引或 stat /
    blob、npm、maven 由 `getFileInfo` 转换），须确认 `path` 存在且为普通文件后传入（本函数不再自检）。
    `info.gzSize` 非 0 且客户端接受 gzip、无 Range 时发送 `path.gz`（sidecar 由部署期预压缩生成，
    如 www auto-gzip / asset 非 `<dir>` 强制；不再有后台压缩线程）。
    stat 与读盘之间存在 TOCTOU 窗口，文件被删除/替换时按读盘失败既有逻辑兜底。
*/
void sendFile(scope HTTPServerRequest req, scope HTTPServerResponse res,
    string path, ref const(IndexedFileInfo) info, immutable(CachePolicy) policy,
    SendFileHook preWrite = null) {
  sendFileImpl(req, res, NativePath(path), info, policy, preWrite);
}

private void sendFileImpl(scope HTTPServerRequest req, scope HTTPServerResponse res, NativePath path,
    ref const(IndexedFileInfo) info, immutable(CachePolicy) policy, SendFileHook preWrite) {
  auto pathstr = path.toNativeString();
  auto dirent = info.toFileInfo(pathstr);
  if (dirent.isDirectory) {
    throw new HTTPStatusException(HTTPStatus.notFound);
  }

  auto prange = "Range" in req.headers;
  bool gzip;
  NativePath contentPath = path;
  // 预压缩 sidecar：`info.gzSize` 由调用方预取（www 索引 / asset 强制），部署期预压缩仅覆盖可压缩白名单，
  // 非 0 即存在变体，无需再按扩展名判断；客户端接受 gzip 且无 Range 时发送 gz。
  // Content-Type 仍按原文件名取；ETag/Last-Modified 复用源文件信息（gz 是其编码表示）、Content-Length 用 gz 实际大小。
  if (info.gzSize != 0 && acceptsGzip(req) && prange is null) {
    dirent.size = info.gzSize;
    contentPath = NativePath(pathstr ~ ".gz");
    gzip = true;
  }

  // 存在 gz 变体的内容无论本次是否实际发送 gz 都声明 Vary（放在 handleCacheFile 之前，
  // 使 304 条件响应同样携带，RFC 7232 §4.1），避免缓存固化单份原版后压缩版无法命中。
  // 无变体（不可压缩或未生成 sidecar）不声明。
  if (info.gzSize != 0)
    res.headers["Vary"] = "Accept-Encoding";

  if (handleCacheFile(req, res, dirent, policy.cacheControl, policy.maxAge)) {
    return;
  }

  if (!("Content-Type" in res.headers)) {
    res.headers["Content-Type"] = res.headers.get("Content-Type", getMimeTypeForFile(pathstr));
  }
  res.headers.addField("Accept-Ranges", "bytes");
  res.headers.addField("Access-Control-Allow-Origin", "*");
  if (gzip) {
    res.headers["Content-Encoding"] = "gzip";
  }

  ulong rangeStart = 0;
  ulong rangeEnd = 0;

  if (prange) {
    if (dirent.size == 0) {
      res.headers["Content-Length"] = "0";
      res.headers["Content-Range"] = "bytes */0";
      res.statusCode = cast(HTTPStatus) 416;
      if (preWrite)
        preWrite(req, res);
      res.writeVoidBody();
      return;
    }
    auto range = (*prange).chompPrefix("bytes=");
    auto startend = parseRange(range, dirent.size);
    rangeStart = startend[0];
    rangeEnd = startend[1];
    res.headers["Content-Length"] = to!string(rangeEnd - rangeStart + 1);
    res.headers["Content-Range"] = "bytes %s-%s/%s".format(rangeStart < rangeEnd
        ? rangeStart : rangeEnd, rangeEnd, dirent.size);
    res.statusCode = HTTPStatus.partialContent;
  } else
    res.headers["Content-Length"] = dirent.size.to!string;

  if (preWrite)
    preWrite(req, res);

  if (res.isHeadResponse()) {
    res.writeVoidBody();
    return;
  }
  if (!prange && dirent.size <= maxWholeFileMemSend) {
    ubyte[] data = readFile(contentPath);
    // gzip 分支走原始写通道：vibe 的 bodyWriter 在 `Content-Encoding: gzip` 时会
    // 移除 Content-Length 并把输出流再包一层 gzip（假定应用写未压缩内容），
    // 对预压缩 sidecar 会造成二次压缩；writeRawBody 不做任何进一步编码。
    if (gzip)
      res.writeRawBody(createMemoryStream(data));
    else
      res.bodyWriter.write(data);
    return;
  }

  FileStream fil;
  try {
    fil = openFile(contentPath);
  } catch (Exception e) {
    return;
  }
  scope (exit)
    fil.close();

  if (prange) {
    fil.seek(rangeStart);
    fil.pipe(res.bodyWriter, rangeEnd - rangeStart + 1);
  } else if (gzip) {
    res.writeRawBody(fil);
  } else {
    fil.pipe(res.bodyWriter);
  }
}
