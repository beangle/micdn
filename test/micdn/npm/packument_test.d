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

module test.micdn.npm.packument_test;

import std.algorithm : min;
import std.array : replicate;
import std.base64;
import std.conv : octal, to;
import std.digest : toHexString, LetterCase;
import std.digest.sha : sha1Of;
import std.exception : assertThrown;
import std.file;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path;
import std.uuid : randomUUID;
import std.zlib : Compress, HeaderFormat;

import micdn.npm.packument : installTarball;

// ---- 造包：最小 ustar 头 + gzip（与 test/micdn/fs/tar_test.d 同口径，只造普通文件）----

private string tarOctField(ulong v, size_t digits) {
  auto s = to!string(v, 8);
  if (s.length > digits)
    s = s[$ - digits .. $];
  return "0".replicate(digits - s.length) ~ s;
}

private ubyte[] tarFileEntry(string name, const(ubyte)[] content) {
  ubyte[512] hdr;
  void put(size_t off, size_t len, const(char)[] s) {
    auto n = min(len, s.length);
    hdr[off .. off + n] = cast(ubyte[]) s[0 .. n];
  }
  put(0, 100, name);
  put(100, 8, tarOctField(octal!644, 7) ~ "\0");
  put(108, 8, tarOctField(0, 7) ~ "\0");
  put(116, 8, tarOctField(0, 7) ~ "\0");
  put(124, 12, tarOctField(content.length, 11) ~ "\0");
  put(136, 12, tarOctField(0, 11) ~ "\0");
  hdr[156] = cast(ubyte) '0';
  put(257, 6, "ustar\0");
  put(263, 2, "00");
  uint sum;
  foreach (i; 0 .. 512) {
    auto b = hdr[i];
    if (i >= 148 && i < 156)
      b = 0x20;
    sum += b;
  }
  put(148, 8, format("%06o", sum) ~ "\0 ");

  ubyte[] block;
  block ~= hdr[];
  block ~= content;
  auto pad = (512 - (content.length % 512)) % 512;
  block.length += pad;
  return block;
}

/// 写一个含 `package/package.json` 的 tgz，返回其路径。
private string makeTgz(string dir, string manifestJson) {
  mkdirRecurse(dir);
  auto path = dir ~ "/" ~ randomUUID().toString() ~ ".tgz";
  ubyte[] tar = tarFileEntry("package/package.json", cast(ubyte[]) manifestJson);
  auto c = new Compress(9, HeaderFormat.gzip);
  ubyte[] gz;
  gz ~= cast(ubyte[]) c.compress(tar);
  gz ~= cast(ubyte[]) c.flush();
  std.file.write(path, gz);
  return path;
}

private string tempBase(string tag) {
  auto dir = buildPath(tempDir(), "micdn_npm_packument_" ~ tag ~ "_" ~ randomUUID().toString());
  mkdirRecurse(dir);
  return absolutePath(dir);
}

private JSONValue readDoc(string path) {
  return parseJSON(readText(path));
}

@("installTarball: copies the tgz into the cache layout and writes the packument")
unittest {
  auto work = tempBase("install");
  scope (exit)
    if (exists(work))
      rmdirRecurse(work);
  auto tgz = makeTgz(work ~ "/src",
      `{"name":"@xurp/manual","version":"0.0.2","description":"demo","license":"LGPL",` ~
      `"scripts":{"build":"x"},"devDependencies":{"z":"1"}}`);

  auto result = installTarball(work ~ "/npm", tgz, "http://cdn/npm", "");

  assert(result.name == "@xurp/manual" && result.ver == "0.0.2");
  assert(result.tarball == work ~ "/npm/xurp/manual/0.0.2/manual-0.0.2.tgz", result.tarball);
  assert(exists(result.tarball), "tgz must be copied into the cache layout");
  assert(cast(const(ubyte)[]) read(result.tarball) == cast(const(ubyte)[]) read(tgz),
      "cached tgz must match the source bytes");
  assert(result.packument == work ~ "/npm/@xurp/manual");
  assert(result.url == "http://cdn/npm/@xurp/manual/-/manual-0.0.2.tgz");
  assert(result.versions == ["0.0.2"]);

  auto doc = readDoc(result.packument);
  auto manifest = doc["versions"]["0.0.2"];
  assert(doc["name"].str == "@xurp/manual" && doc["_id"].str == "@xurp/manual");
  assert(doc["dist-tags"]["latest"].str == "0.0.2");
  assert(manifest["dist"]["tarball"].str == result.url);
  assert(("scripts" in manifest.object) is null, "scripts must be stripped");
  assert(("devDependencies" in manifest.object) is null, "devDependencies must be stripped");
  assert(manifest["dist"]["shasum"].str
      == toHexString!(LetterCase.lower)(sha1Of(cast(const(ubyte)[]) read(result.tarball))));
  assert(doc["description"].str == "demo" && doc["license"].str == "LGPL");
}

@("installTarball: prereleases get a channel tag while latest stays stable")
unittest {
  auto work = tempBase("tags");
  scope (exit)
    if (exists(work))
      rmdirRecurse(work);
  auto base = work ~ "/npm";
  installTarball(base, makeTgz(work ~ "/src", `{"name":"lib","version":"0.0.2"}`),
      "http://cdn/npm", "");
  auto result = installTarball(base, makeTgz(work ~ "/src", `{"name":"lib","version":"0.0.3-dev.1"}`),
      "http://cdn/npm", "");

  auto doc = readDoc(result.packument);
  assert(result.versions == ["0.0.2", "0.0.3-dev.1"], result.versions.to!string);
  assert(doc["dist-tags"]["latest"].str == "0.0.2", "latest must ignore prereleases");
  assert(doc["dist-tags"]["dev"].str == "0.0.3-dev.1");
  assert(doc["time"].object.length == 4, "created/modified plus one entry per version");
}

@("installTarball: prerelease identifiers compare numerically")
unittest {
  auto work = tempBase("semver");
  scope (exit)
    if (exists(work))
      rmdirRecurse(work);
  auto base = work ~ "/npm";
  installTarball(base, makeTgz(work ~ "/src", `{"name":"lib","version":"2.0.0-rc.2"}`),
      "http://cdn/npm", "");
  installTarball(base, makeTgz(work ~ "/src", `{"name":"lib","version":"2.0.0-rc.10"}`),
      "http://cdn/npm", "");
  auto result = installTarball(base, makeTgz(work ~ "/src", `{"name":"lib","version":"2.0.0"}`),
      "http://cdn/npm", "");

  auto doc = readDoc(result.packument);
  assert(result.versions == ["2.0.0-rc.2", "2.0.0-rc.10", "2.0.0"], result.versions.to!string);
  assert(doc["dist-tags"]["latest"].str == "2.0.0");
  assert(doc["dist-tags"]["rc"].str == "2.0.0-rc.10", "rc.10 must beat rc.2");
}

@("installTarball: custom tags persist, same-version reinstall refreshes bytes")
unittest {
  auto work = tempBase("retag");
  scope (exit)
    if (exists(work))
      rmdirRecurse(work);
  auto base = work ~ "/npm";
  installTarball(base, makeTgz(work ~ "/src", `{"name":"lib","version":"1.0.0"}`),
      "http://cdn/npm", "stable");
  auto result = installTarball(base, makeTgz(work ~ "/src", `{"name":"lib","version":"1.0.1"}`),
      "http://cdn/npm", "");

  auto doc = readDoc(result.packument);
  assert(doc["dist-tags"]["stable"].str == "1.0.0", "custom tag must survive later installs");
  assert(doc["dist-tags"]["latest"].str == "1.0.1");
  assert(result.versions.length == 2);

  // 覆盖重发同名版本：仍是两条版本记录，shasum 跟着新字节走。
  auto replaced = makeTgz(work ~ "/src2", `{"name":"lib","version":"1.0.1","description":"rebuilt"}`);
  auto again = installTarball(base, replaced, "http://cdn/npm", "");
  auto doc2 = readDoc(again.packument);
  assert(again.versions.length == 2, "reinstall must not duplicate the version");
  assert(doc2["versions"]["1.0.1"]["description"].str == "rebuilt");
  assert(doc2["versions"]["1.0.1"]["dist"]["shasum"].str
      == toHexString!(LetterCase.lower)(sha1Of(cast(const(ubyte)[]) read(replaced))));
  assert(doc2["dist-tags"]["stable"].str == "1.0.0", "custom tag kept after reinstall");
}

@("installTarball: rejects missing, malformed and unsafe packages")
unittest {
  auto work = tempBase("bad");
  scope (exit)
    if (exists(work))
      rmdirRecurse(work);
  auto base = work ~ "/npm";

  assertThrown(installTarball(base, work ~ "/nope.tgz", "http://cdn/npm", ""));
  // 有 tgz 但没有 package/package.json
  auto empty = work ~ "/empty.tgz";
  auto c = new Compress(9, HeaderFormat.gzip);
  ubyte[] tar = tarFileEntry("package/README.md", cast(ubyte[]) "x");
  ubyte[] gz;
  gz ~= cast(ubyte[]) c.compress(tar);
  gz ~= cast(ubyte[]) c.flush();
  std.file.write(empty, gz);
  assertThrown(installTarball(base, empty, "http://cdn/npm", ""));
  // 非法包名 / 版本 / tag 不落盘
  assertThrown(installTarball(base, makeTgz(work ~ "/src", `{"name":"../evil","version":"1.0.0"}`),
      "http://cdn/npm", ""));
  assertThrown(installTarball(base, makeTgz(work ~ "/src", `{"name":"lib","version":"../evil"}`),
      "http://cdn/npm", ""));
  assertThrown(installTarball(base, makeTgz(work ~ "/src", `{"version":"1.0.0"}`), "http://cdn/npm", ""));
  assertThrown(installTarball(base, makeTgz(work ~ "/src", `{"name":"lib","version":"1.0.0"}`),
      "http://cdn/npm", "bad tag"));
  assert(!exists(base ~ "/evil"), "unsafe name must not create anything");
}
