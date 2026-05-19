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
import std.array;
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

/// 无 Range 时整文件若不超过此大小则读入内存再写出，避免 `FileStream` 与 `bodyWriter` 组合在部分场景下的句柄/GC 告警。
private enum maxWholeFileMemSend = 8u * 1024 * 1024;
import vibe.http.fileserver;
import vibe.http.server;
import vibe.inet.message;
import vibe.inet.mimetypes;

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
 */
bool curlDownload(string url, string local) {
  import std.process, std.file, std.path, std.conv, std.datetime;

  mkdirRecurse(dirName(local));
  auto tmpPath = dirName(local) ~ "/." ~ baseName(local) ~ ".part";
  scope (exit) {
    if (exists(tmpPath))
      remove(tmpPath);
  }

  auto cmd = execute(["curl", "--fail", "--silent", "--show-error", "-L",
      "--connect-timeout", "10",
      "--max-time", "300",
      "--speed-time", "30",
      "--speed-limit", "1024",
      "-o", tmpPath, url]);
  import vibe.core.log;

  if (cmd.status != 0) {
    logWarn("Download failure %s due to %s", url, cmd.output);
    return false;
  }
  if (!exists(tmpPath)) {
    logWarn("Download failure %s due to %s", url, cmd.output);
    return false;
  }
  rename(tmpPath, local);
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

/** 发送单个文件；`policy` 必选，见 `micdn.web.cache`。 */
void sendFile(scope HTTPServerRequest req, scope HTTPServerResponse res,
    string path, immutable(CachePolicy) policy, SendFileHook preWrite = null) {
  sendFileImpl(req, res, NativePath(path), policy, preWrite);
}

/** 按顺序拼接多个文件；`policy` 必选。 */
void sendFiles(scope HTTPServerRequest req, scope HTTPServerResponse res,
    string[] paths, immutable(CachePolicy) policy, SendFileHook preWrite = null) {
  auto npaths = array(paths.map!(p => NativePath(p)));
  sendFilesImpl(req, res, npaths, policy, preWrite);
}

private void sendFileImpl(scope HTTPServerRequest req, scope HTTPServerResponse res, NativePath path,
    immutable(CachePolicy) policy, SendFileHook preWrite) {
  auto pathstr = path.toNativeString();
  if (!existsFile(pathstr))
    throw new HTTPStatusException(HTTPStatus.notFound);

  FileInfo dirent;
  try
    dirent = getFileInfo(pathstr);
  catch (Exception) {
    throw new HTTPStatusException(HTTPStatus.internalServerError,
        "Failed to get information for the file due to a file system error.");
  }

  if (dirent.isDirectory) {
    throw new HTTPStatusException(HTTPStatus.notFound);
  }

  if (handleCacheFile(req, res, dirent, policy.cacheControl, policy.maxAge)) {
    return;
  }

  if (!("Content-Type" in res.headers)) {
    res.headers["Content-Type"] = res.headers.get("Content-Type", getMimeTypeForFile(pathstr));
  }
  res.headers.addField("Accept-Ranges", "bytes");
  res.headers.addField("Access-Control-Allow-Origin", "*");

  ulong rangeStart = 0;
  ulong rangeEnd = 0;
  auto prange = "Range" in req.headers;

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
    ubyte[] data = readFile(path);
    res.bodyWriter.write(data);
    return;
  }

  FileStream fil;
  try {
    fil = openFile(path);
  } catch (Exception e) {
    return;
  }
  scope (exit)
    fil.close();

  if (prange) {
    fil.seek(rangeStart);
    fil.pipe(res.bodyWriter, rangeEnd - rangeStart + 1);
  } else {
    fil.pipe(res.bodyWriter);
  }
}

private void sendFilesImpl(scope HTTPServerRequest req, scope HTTPServerResponse res, NativePath[] paths,
    immutable(CachePolicy) policy, SendFileHook preWrite) {
  auto firstPath = paths[0].toNativeString();
  auto infos = paths.map!(p => getFileInfo(p.toNativeString()));
  if (handleCacheFile(req, res, infos[0], policy.cacheControl, policy.maxAge)) {
    return;
  }
  assert(infos.length > 0);
  ulong size = infos.map!(i => i.size).sum;
  ulong separatorCount = 0;
  foreach (_; 1 .. infos.length)
    separatorCount++;
  size += separatorCount;

  if (!("Content-Type" in res.headers)) {
    res.headers["Content-Type"] = res.headers.get("Content-Type", getMimeTypeForFile(firstPath));
  }
  res.headers["Content-Length"] = size.to!string;

  if (preWrite)
    preWrite(req, res);

  if (res.isHeadResponse()) {
    res.writeVoidBody();
    return;
  }

  FileStream[] fss;
  fss.reserve(paths.length);
  foreach (ref p; paths) {
    try {
      fss ~= openFile(p);
    } catch (Exception e) {
      foreach (ref x; fss)
        x.close();
      return;
    }
  }

  scope (exit) {
    foreach (ref fs; fss)
      fs.close();
  }
  int processed = 0;
  foreach (ref fs; fss) {
    fs.pipe(res.bodyWriter);
    processed += 1;
    if (processed < fss.length) {
      res.writeBody("\n");
    }
  }
}
