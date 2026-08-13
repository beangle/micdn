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

module test.micdn.web.file_test;

import std.file;
import std.path;
import std.uuid : randomUUID;
import std.zlib : UnCompress, HeaderFormat;
import std.string : indexOf;
import std.algorithm : canFind;

import vibe.http.common : HTTPMethod, HTTPStatus;
import vibe.http.server : HTTPStatusException, createTestHTTPServerRequest, createTestHTTPServerResponse, TestHTTPResponseMode;
import vibe.core.file : FileInfo, getFileInfo;
import vibe.inet.message : InetHeaderMap, toRFC822DateTimeString;
import vibe.inet.url : URL;
import vibe.stream.memory : createMemoryOutputStream;

import micdn.web.cache;
import micdn.web.file;
import micdn.web.gzip;
import micdn.fs.index;
import std.exception : assertThrown;

/// 由 vibe `FileInfo` 构造 sendFile 所需条目；`withGz` 时附加同目录 sidecar 大小（0 = 无）。
private IndexedFileInfo indexInfoOf(string path, ref const(FileInfo) fi, bool withGz = false) {
  auto info = IndexedFileInfo.fromFileInfo(fi);
  if (withGz) {
    auto gzPath = path ~ ".gz";
    if (exists(gzPath))
      info.gzSize = getSize(gzPath);
  }
  return info;
}

@("web file range encode")
unittest {
  auto s = encodeAttachmentName("早上 好.txt");
  auto expected = `attachment; filename="%E6%97%A9%E4%B8%8A%20%E5%A5%BD.txt";`
                   ~` filename*=utf-8''%E6%97%A9%E4%B8%8A%20%E5%A5%BD.txt`;
  assert(s == expected);
  auto r1 = parseRange("0-1", 2);
  assert(r1 == [0, 1]);

  auto r2 = parseRange("9500-", 10_000);
  auto r3 = parseRange("-500", 10_000);
  assert(r2 == r3);

  auto r4 = parseRange("9500-100002", 10_000);
  assert(r2 == r4);

  auto r5 = parseRange("10000-100002", 10_000);
  assert(r5 == [9999, 9999]);

  assertThrown(parseRange("0-", 0));
  assertThrown(parseRange("-1", 0));
}

private string gzipTestContent() {
  string content;
  foreach (i; 0 .. 2000)
    content ~= "console.log('micdn gzip');\n";
  return content;
}

private string decompressAll(ubyte[] data) {
  auto u = new UnCompress(HeaderFormat.gzip);
  ubyte[] plain;
  plain ~= cast(ubyte[]) u.uncompress(data);
  plain ~= cast(ubyte[]) u.flush();
  return cast(string) plain;
}

@("web sendFile serves pre-compressed gzip sidecar")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) rmdirRecurse(dir);

  auto f = buildPath(dir, "a.js");
  auto content = gzipTestContent();
  write(f, content);
  assert(gzipFile(f));

  InetHeaderMap headers;
  headers["Accept-Encoding"] = "gzip";
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js"), HTTPMethod.GET, headers, null);
  // plain 模式走真实 HTTP1 写出路径：可验证 Content-Length 保留与无二次压缩
  // （bodyOnly 模式预置 bodyWriter，会绕过 vibe 的 Content-Encoding 处理分支）。
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.plain);
  auto fi = getFileInfo(f);
  auto info = indexInfoOf(f, fi, true);
  sendFile(req, res, f, info, publicMaxAge1yImmutable);

  assert(res.headers["Content-Encoding"] == "gzip", "Content-Encoding should be gzip");
  assert(res.headers["Vary"] == "Accept-Encoding");

  auto wire = cast(string) output.data;
  auto sep = wire.indexOf("\r\n\r\n");
  assert(sep > 0, "plain mode should capture raw HTTP response");
  auto head = wire[0 .. sep];
  auto body = wire[sep + 4 .. $];
  assert(head.canFind("Content-Length: "), "gzip response must keep Content-Length");
  assert(!head.canFind("Transfer-Encoding: chunked"), "gzip response must not be chunked");
  assert(body.length < content.length, "gzip body should be smaller");
  assert(decompressAll(cast(ubyte[]) body) == content, "single decompress must yield original (no double gzip)");
}

@("web sendFile serves original when client does not accept gzip")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) rmdirRecurse(dir);

  auto f = buildPath(dir, "a.js");
  auto content = gzipTestContent();
  write(f, content);
  assert(gzipFile(f));

  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js"), HTTPMethod.GET, InetHeaderMap.init, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  auto fi = getFileInfo(f);
  auto info = indexInfoOf(f, fi, true);
  sendFile(req, res, f, info, publicMaxAge1yImmutable);

  assert(!("Content-Encoding" in res.headers), "no Content-Encoding without Accept-Encoding");
  assert(res.headers["Vary"] == "Accept-Encoding", "identity response of gzip-eligible content must declare Vary");
  assert(cast(string) output.data == content);
}

@("web sendFile omits Vary for incompressible files")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) rmdirRecurse(dir);

  auto f = buildPath(dir, "a.png");
  write(f, cast(ubyte[]) [0x89, 0x50, 0x4E, 0x47]);

  InetHeaderMap headers;
  headers["Accept-Encoding"] = "gzip";
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.png"), HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  auto fi = getFileInfo(f);
  auto info = indexInfoOf(f, fi);
  sendFile(req, res, f, info, publicMaxAge1yImmutable);

  assert(!("Content-Encoding" in res.headers));
  assert(!("Vary" in res.headers), "incompressible content must not declare Vary");
}

@("web sendFile declares Vary on 304 not-modified")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) rmdirRecurse(dir);

  auto f = buildPath(dir, "a.js");
  write(f, gzipTestContent());
  assert(gzipFile(f), "gz variant should pre-exist for the Vary-on-304 case");
  auto fi = getFileInfo(f);
  // sendFile 从绝对时刻（stdTime）重建 SysTime 时统一按 UTC 输出 Last-Modified（GMT），
  // If-Modified-Since 需取同一 UTC 表示才字符串相等（避免 vibe 数值比较的亚秒截断问题）。
  auto mt = toRFC822DateTimeString(fi.timeModified.toUTC());

  InetHeaderMap headers;
  headers["If-Modified-Since"] = mt;
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js"), HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  auto info = indexInfoOf(f, fi, true);
  sendFile(req, res, f, info, publicMaxAge1yImmutable);

  assert(res.statusCode == HTTPStatus.notModified);
  assert(res.headers["Vary"] == "Accept-Encoding", "304 with a gz variant must declare Vary like the 200 it validates");
  assert(output.data.length == 0);
}

@("web sendFile skips gzip for Range requests")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) rmdirRecurse(dir);

  auto f = buildPath(dir, "a.js");
  auto content = gzipTestContent();
  write(f, content);
  assert(gzipFile(f));

  InetHeaderMap headers;
  headers["Accept-Encoding"] = "gzip";
  headers["Range"] = "bytes=0-3";
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js"), HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  auto fi = getFileInfo(f);
  auto info = indexInfoOf(f, fi, true);
  sendFile(req, res, f, info, publicMaxAge1yImmutable);

  assert(res.statusCode == HTTPStatus.partialContent);
  assert(!("Content-Encoding" in res.headers), "Range responses must serve original file");
  assert(res.headers["Vary"] == "Accept-Encoding", "gzip-eligible content must declare Vary even on Range responses");
  assert(cast(string) output.data == content[0 .. 4]);
}

@("sendFile without gzSize never creates sidecar")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) {
    if (exists(dir))
      rmdirRecurse(dir);
  }

  auto f = buildPath(dir, "a.js");
  write(f, gzipTestContent());

  InetHeaderMap headers;
  headers["Accept-Encoding"] = "gzip";
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js"), HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  auto fi = getFileInfo(f);
  auto info = indexInfoOf(f, fi);
  sendFile(req, res, f, info, publicMaxAge1yImmutable);

  assert(!exists(f ~ ".gz"), "without gzSize nothing is created");
}

@("sendFile without gzSize ignores existing gzip sidecar")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) {
    if (exists(dir))
      rmdirRecurse(dir);
  }

  auto f = buildPath(dir, "a.js");
  auto content = gzipTestContent();
  write(f, content);
  assert(gzipFile(f), "sidecar should pre-exist");

  InetHeaderMap headers;
  headers["Accept-Encoding"] = "gzip";
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js"), HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  auto fi = getFileInfo(f);
  auto info = indexInfoOf(f, fi);
  sendFile(req, res, f, info, publicMaxAge1yImmutable);

  assert(!("Content-Encoding" in res.headers), "without gzSize must serve original even with sidecar");
  assert(cast(string) output.data == content);
}

@("sendFile ignores gzSize without Accept-Encoding")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) {
    if (exists(dir))
      rmdirRecurse(dir);
  }

  auto f = buildPath(dir, "a.js");
  auto content = gzipTestContent();
  write(f, content);
  assert(gzipFile(f), "sidecar should pre-exist");

  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js"), HTTPMethod.GET, InetHeaderMap.init, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  auto fi = getFileInfo(f);
  auto info = indexInfoOf(f, fi, true);
  sendFile(req, res, f, info, publicMaxAge1yImmutable);

  assert(!("Content-Encoding" in res.headers), "without Accept-Encoding sidecar is ignored");
  assert(cast(string) output.data == content);
}

@("sendFile serves from caller-provided FileInfo")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-fi-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) rmdirRecurse(dir);

  auto f = buildPath(dir, "a.js");
  write(f, "var a = 1;");
  auto fi = getFileInfo(f);

  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js"), HTTPMethod.GET, InetHeaderMap.init, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  auto info = indexInfoOf(f, fi);
  sendFile(req, res, f, info, publicMaxAge1yImmutable);

  assert(cast(string) output.data == "var a = 1;");
  assert(res.headers["Content-Length"] == "10");
}

@("sendFile rejects caller-provided directory FileInfo")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-fidir-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) rmdirRecurse(dir);

  auto fi = getFileInfo(dir);
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/"), HTTPMethod.GET, InetHeaderMap.init, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  auto info = indexInfoOf(dir, fi);
  assertThrown!HTTPStatusException(sendFile(req, res, dir, info, publicMaxAge1yImmutable));
}
