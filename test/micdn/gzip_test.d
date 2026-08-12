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

module test.micdn.gzip_test;

import std.conv : to;
import std.file;
import std.path : buildPath;
import std.uuid : randomUUID;
import std.zlib : UnCompress, HeaderFormat;

import core.thread : Thread;
import core.time : msecs;

import vibe.http.common : HTTPMethod;
import vibe.http.server : createTestHTTPServerRequest;
import vibe.inet.message : InetHeaderMap;
import vibe.inet.url : URL;

import micdn.gzip;
import micdn.fs.file : makeSymlink;

private string tmpBase() {
  return buildPath(tempDir(), "micdn-gzip-" ~ randomUUID().toString);
}

private string sampleContent() {
  string content;
  foreach (i; 0 .. 3000)
    content ~= "console.log('micdn gzip roundtrip');\n";
  return content;
}

@("gzip eligibility by extension")
unittest {
  assert(isGzipEligible("/tmp/a.js"));
  assert(isGzipEligible("/tmp/a.min.css"));
  assert(isGzipEligible("/tmp/a.html"));
  assert(isGzipEligible("/tmp/a.svg"));
  assert(isGzipEligible("/tmp/a.json"));
  assert(!isGzipEligible("/tmp/a.png"));
  assert(!isGzipEligible("/tmp/a.woff2"));
  assert(!isGzipEligible("/tmp/a.gz"));
  assert(!isGzipEligible("/tmp/a"));

  assert(!isGzipSized(0));
  assert(!isGzipSized(minGzipFileSize - 1));
  assert(isGzipSized(minGzipFileSize));
  assert(isGzipSized(maxGzipFileSize));
  assert(!isGzipSized(maxGzipFileSize + 1));
}

@("gzip Accept-Encoding parsing")
unittest {
  bool accepts(string ae) {
    InetHeaderMap headers;
    headers["Accept-Encoding"] = ae;
    auto req = createTestHTTPServerRequest(URL("http://localhost/x.js"), HTTPMethod.GET, headers, null);
    return acceptsGzip(req);
  }

  assert(accepts("gzip"));
  assert(accepts("gzip, deflate, br, zstd"));
  assert(accepts("GZip"));
  assert(accepts("gzip ; q=1"));
  assert(accepts("deflate, gzip, br"));
  assert(accepts("gzip;q=1;level=5"));
  assert(accepts("*"));
  assert(accepts("gzip;q=0.5"));
  assert(accepts("gzip; q=1"));
  assert(!accepts("identity"));
  assert(!accepts("br, zstd"));
  assert(!accepts("deflate;q=1, *;q=0"));
  assert(!accepts("gzip;q=0"));
  assert(!accepts("gzip;q=0, *;q=1"));
  assert(!accepts(""));
  assert(!accepts("br"));

  auto req = createTestHTTPServerRequest(URL("http://localhost/x.js"), HTTPMethod.GET, InetHeaderMap.init, null);
  assert(!acceptsGzip(req), "missing Accept-Encoding must not accept gzip");
}

@("gzipFile creates smaller sidecar and roundtrips")
unittest {
  auto dir = tmpBase();
  mkdirRecurse(dir);
  scope (exit) {
    if (exists(dir))
      rmdirRecurse(dir);
  }
  auto f = buildPath(dir, "app.js");
  auto content = sampleContent();
  write(f, content);

  assert(gzipFile(f));
  auto gz = f ~ ".gz";
  assert(exists(gz), "sidecar should exist");
  assert(getSize(gz) < getSize(f), "sidecar should be smaller than original");

  auto u = new UnCompress(HeaderFormat.gzip);
  ubyte[] plain;
  plain ~= cast(ubyte[]) u.uncompress(read(gz));
  plain ~= cast(ubyte[]) u.flush();
  assert(cast(string) plain == content, "decompressed sidecar should equal original");

  assert(gzipFile(f), "existing sidecar should be idempotent");
}

@("gzipFile skips tiny files and non-eligible extensions")
unittest {
  auto dir = tmpBase();
  mkdirRecurse(dir);
  scope (exit) {
    if (exists(dir))
      rmdirRecurse(dir);
  }

  auto tiny = buildPath(dir, "t.js");
  write(tiny, "x");
  assert(!gzipFile(tiny), "tiny file should not be compressed");
  assert(!exists(tiny ~ ".gz"));

  auto img = buildPath(dir, "img.png");
  write(img, cast(ubyte[]) [0x89, 0x50, 0x4E, 0x47]);
  assert(!gzipFile(img), "non-eligible extension should not be compressed");
  assert(!exists(img ~ ".gz"));

  auto missing = buildPath(dir, "nope.js");
  assert(!gzipFile(missing));
}

version (Posix) {
  @("gzipFile skips symlinks")
  unittest {
    auto dir = tmpBase();
    mkdirRecurse(dir);
    scope (exit) {
      if (exists(dir))
        rmdirRecurse(dir);
    }
    auto target = buildPath(dir, "real.js");
    write(target, sampleContent());
    auto link = buildPath(dir, "link.js");
    makeSymlink(target, link);
    assert(!gzipFile(link), "symlink should not be compressed in place");
    assert(!exists(link ~ ".gz"));
  }
}

@("background queue compresses enqueued file")
unittest {
  auto dir = tmpBase();
  mkdirRecurse(dir);
  scope (exit) {
    stopGzipWorker();
    if (exists(dir))
      rmdirRecurse(dir);
  }
  auto f = buildPath(dir, "bundle.js");
  auto content = sampleContent();
  write(f, content);

  enqueueGzip(f);
  auto gz = f ~ ".gz";
  foreach (_; 0 .. 200) {
    if (exists(gz))
      break;
    Thread.sleep(50.msecs);
  }
  assert(exists(gz), "worker should create sidecar for enqueued file");

  auto u = new UnCompress(HeaderFormat.gzip);
  ubyte[] plain;
  plain ~= cast(ubyte[]) u.uncompress(read(gz));
  plain ~= cast(ubyte[]) u.flush();
  assert(cast(string) plain == content, "worker sidecar should match original");
}
