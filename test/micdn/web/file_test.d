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

import core.thread : Thread;
import core.time : msecs;

import vibe.http.common : HTTPMethod, HTTPStatus;
import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse, TestHTTPResponseMode;
import vibe.core.file : getFileInfo;
import vibe.inet.message : InetHeaderMap, toRFC822DateTimeString;
import vibe.inet.url : URL;
import vibe.stream.memory : createMemoryOutputStream;

import micdn.web.cache;
import micdn.web.file;
import micdn.web.gzip;
import std.exception : assertThrown;

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

@("web sendFiles concatenates small files in memory")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfiles-test");
  mkdirRecurse(dir);
  scope (exit) rmdirRecurse(dir);

  auto f1 = buildPath(dir, "a.js");
  auto f2 = buildPath(dir, "b.js");
  write(f1, "console.log(1);");
  write(f2, "console.log(2);");

  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js,b.js"), HTTPMethod.GET, InetHeaderMap.init, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  sendFiles(req, res, [f1, f2], publicMaxAge1yImmutable);
  assert(cast(string) output.data == "console.log(1);\nconsole.log(2);");
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
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  sendFile(req, res, f, publicMaxAge1yImmutable, null, true);

  assert(res.headers["Content-Encoding"] == "gzip", "Content-Encoding should be gzip");
  assert(res.headers["Vary"] == "Accept-Encoding");
  assert(output.data.length < content.length, "gzip body should be smaller");
  assert(decompressAll(output.data) == content, "gzip body should decompress to original");
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
  sendFile(req, res, f, publicMaxAge1yImmutable, null, true);

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
  sendFile(req, res, f, publicMaxAge1yImmutable, null, true);

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
  auto mt = toRFC822DateTimeString(getFileInfo(f).timeModified);

  InetHeaderMap headers;
  headers["If-Modified-Since"] = mt;
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js"), HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  sendFile(req, res, f, publicMaxAge1yImmutable, null, true);

  assert(res.statusCode == HTTPStatus.notModified);
  assert(res.headers["Vary"] == "Accept-Encoding", "304 must declare Vary like the 200 it validates");
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
  sendFile(req, res, f, publicMaxAge1yImmutable, null, true);

  assert(res.statusCode == HTTPStatus.partialContent);
  assert(!("Content-Encoding" in res.headers), "Range responses must serve original file");
  assert(res.headers["Vary"] == "Accept-Encoding", "gzip-eligible content must declare Vary even on Range responses");
  assert(cast(string) output.data == content[0 .. 4]);
}

@("web sendFiles does not gzip comma-merged files")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfiles-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) rmdirRecurse(dir);

  auto f1 = buildPath(dir, "a.js");
  auto f2 = buildPath(dir, "b.js");
  auto c1 = gzipTestContent();
  auto c2 = gzipTestContent();
  write(f1, c1);
  write(f2, c2);
  assert(gzipFile(f1));
  assert(gzipFile(f2));

  InetHeaderMap headers;
  headers["Accept-Encoding"] = "gzip";
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js,b.js"), HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  sendFiles(req, res, [f1, f2], publicMaxAge1yImmutable);

  assert(!("Content-Encoding" in res.headers), "comma-merged responses must not be gzipped");
  assert(cast(string) output.data == c1 ~ "\n" ~ c2);
}

@("sendFile with favorGzip enqueues missing sidecar")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) {
    stopGzipWorker();
    if (exists(dir))
      rmdirRecurse(dir);
  }

  auto f = buildPath(dir, "a.js");
  auto content = gzipTestContent();
  write(f, content);

  InetHeaderMap headers;
  headers["Accept-Encoding"] = "gzip";
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js"), HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  sendFile(req, res, f, publicMaxAge1yImmutable, null, true);

  assert(!("Content-Encoding" in res.headers), "first request serves original while sidecar is generated");
  assert(cast(string) output.data == content);

  auto gz = f ~ ".gz";
  foreach (_; 0 .. 200) {
    if (exists(gz))
      break;
    Thread.sleep(50.msecs);
  }
  assert(exists(gz), "background worker should create the missing sidecar");
  assert(decompressAll(cast(ubyte[]) read(gz)) == content, "sidecar should decompress to original");
}

@("sendFile without favorGzip never creates sidecar")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) {
    stopGzipWorker();
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
  sendFile(req, res, f, publicMaxAge1yImmutable, null, false);

  Thread.sleep(200.msecs);
  assert(!exists(f ~ ".gz"), "favorGzip=false must not enqueue sidecar generation");
}

@("sendFile without favorGzip ignores existing gzip sidecar")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) {
    stopGzipWorker();
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
  sendFile(req, res, f, publicMaxAge1yImmutable, null, false);

  assert(!("Content-Encoding" in res.headers), "favorGzip=false must serve original even with sidecar");
  assert(cast(string) output.data == content);
}

@("sendFile does not enqueue without Accept-Encoding")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) {
    stopGzipWorker();
    if (exists(dir))
      rmdirRecurse(dir);
  }

  auto f = buildPath(dir, "a.js");
  write(f, gzipTestContent());

  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/a.js"), HTTPMethod.GET, InetHeaderMap.init, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  sendFile(req, res, f, publicMaxAge1yImmutable, null, true);

  Thread.sleep(200.msecs);
  assert(!exists(f ~ ".gz"), "without Accept-Encoding nothing should be enqueued");
}

@("sendFile does not enqueue oversized files")
unittest {
  auto dir = buildPath(tempDir(), "micdn-sendfile-gz-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit) {
    stopGzipWorker();
    if (exists(dir))
      rmdirRecurse(dir);
  }

  auto f = buildPath(dir, "big.js");
  write(f, new ubyte[maxGzipFileSize + 1]);

  InetHeaderMap headers;
  headers["Accept-Encoding"] = "gzip";
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/big.js"), HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  sendFile(req, res, f, publicMaxAge1yImmutable, null, true);

  Thread.sleep(200.msecs);
  assert(!exists(f ~ ".gz"), "oversized files must not be enqueued");
}
