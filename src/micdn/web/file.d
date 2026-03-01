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
import vibe.http.fileserver;
import vibe.http.server;
import vibe.inet.message;
import vibe.inet.mimetypes;

import micdn.model;

string encodeAttachmentName(string name) @safe {
  import std.array;
  import vibe.textfilter.urlencode;

  auto filename = name.urlEncode();
  auto n = `attachment; filename="{filename}"; filename*=utf-8''{filename}`;
  return n.replace("{filename}", filename);
}

/**
 * Fetch url and store at local.
 * Downloads to a temp file first, then creates target directory and moves on success.
 * No target directory is created when download fails.
 */
bool curlDownload(string url, string local) {
  import std.process, std.file, std.path, std.conv, std.datetime;

  auto tmpPath = tempDir() ~ "micdn_curl_" ~ to!string(
      Clock.currTime.stdTime) ~ "_" ~ baseName(local);
  scope (exit) {
    if (exists(tmpPath))
      remove(tmpPath);
  }

  auto cmd = execute(["curl", "--fail", "--silent", "-L", "-o", tmpPath, url]);
  import vibe.core.log;

  if (cmd.status != 0) {
    logWarn("Download failure %s due to %s", url, cmd.output);
    return false;
  }
  if (!exists(tmpPath)) {
    logWarn("Download failure %s due to %s", url, cmd.output);
    return false;
  }
  mkdirRecurse(dirName(local));
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

class CacheSetting {
  Duration maxAge = 7.days;
  string cacheControl = null;
  void delegate(scope HTTPServerRequest req, scope HTTPServerResponse res, ref string physicalPath) preWrite = null;
}

CacheSetting default_settings;
static this() {
  default_settings = new CacheSetting();
}

void sendFile(scope HTTPServerRequest req, scope HTTPServerResponse res,
    string path, const CacheSetting settings = null) {
  if (settings) {
    sendFileImpl(req, res, NativePath(path), settings);
  } else {
    sendFileImpl(req, res, NativePath(path), default_settings);
  }
}

void sendFiles(scope HTTPServerRequest req, scope HTTPServerResponse res,
    string[] paths, const CacheSetting settings = null) {
  auto npaths = array(paths.map!(p => NativePath(p)));
  if (settings) {
    sendFilesImpl(req, res, npaths, settings);
  } else {
    sendFilesImpl(req, res, npaths, default_settings);
  }
}

private void sendFileImpl(scope HTTPServerRequest req,
    scope HTTPServerResponse res, NativePath path, const CacheSetting settings = null) {
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

  if (handleCacheFile(req, res, dirent, settings.cacheControl, settings.maxAge)) {
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

  if (settings.preWrite)
    settings.preWrite(req, res, pathstr);

  if (res.isHeadResponse()) {
    res.writeVoidBody();
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
    res.writeRawBody(fil);
  }
}

private void sendFilesImpl(scope HTTPServerRequest req,
    scope HTTPServerResponse res, NativePath[] paths, const CacheSetting settings = null) {
  auto firstPath = paths[0].toNativeString();
  auto infos = paths.map!(p => getFileInfo(p.toNativeString()));
  if (handleCacheFile(req, res, infos[0], settings.cacheControl, settings.maxAge)) {
    return;
  }
  ulong size = infos.map!(i => i.size).sum;
  size += infos.length - 1;

  if (!("Content-Type" in res.headers)) {
    res.headers["Content-Type"] = res.headers.get("Content-Type", getMimeTypeForFile(firstPath));
  }
  res.headers["Content-Length"] = size.to!string;

  if (settings.preWrite)
    settings.preWrite(req, res, firstPath);

  if (res.isHeadResponse()) {
    res.writeVoidBody();
    return;
  }

  import std.range;

  FileStream[] fss;
  try {
    fss = array(paths.map!(p => openFile(p)));
  } catch (Exception e) {
    return;
  }

  scope (exit) {
    if (null != fss) {
      foreach (fs; fss) {
        fs.close();
      }
    }
  }
  int processed = 0;
  foreach (fs; fss) {
    fs.pipe(res.bodyWriter);
    processed += 1;
    if (processed < fss.length) {
      res.writeBody("\n");
    }
  }
}
