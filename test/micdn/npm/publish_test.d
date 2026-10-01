/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.npm.publish_test;

import std.algorithm : min;
import std.array : replicate;
import std.base64;
import std.conv : octal, to;
import std.exception : assertThrown;
import std.file;
import std.format : format;
import std.json : parseJSON;
import std.path;
import std.uuid : randomUUID;
import std.zlib : Compress, HeaderFormat;

import micdn.npm.publish : installPublishedPackument;

// ---- 造包：最小 ustar 头 + gzip（与 test/micdn/npm/packument_test.d 同口径）----

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

private string tempBase() {
  auto dir = buildPath(tempDir(), "micdn_npm_publish_" ~ randomUUID().toString());
  mkdirRecurse(dir);
  return absolutePath(dir);
}

/// 组装最小 npm publish 请求体：单版本 + 单附件（Base64 tgz）。
private string publishBody(string name, string ver, string extraTagJson, string encodedTgz) {
  return `{"name":"` ~ name ~ `","dist-tags":{"latest":"` ~ ver ~ `"` ~ extraTagJson ~ `},`
      ~ `"versions":{"` ~ ver ~ `":{}},`
      ~ `"_attachments":{"pkg-` ~ ver ~ `.tgz":{"content_type":"application/octet-stream",`
      ~ `"data":"` ~ encodedTgz ~ `"}}}`;
}

@("installPublishedPackument decodes _attachments and installs like installTarball")
unittest {
  auto work = tempBase();
  scope (exit)
    if (exists(work))
      rmdirRecurse(work);
  auto tgz = makeTgz(work ~ "/src",
      `{"name":"@xurp/manual","version":"0.0.4","description":"demo"}`);
  auto encoded = cast(string) Base64.encode(cast(const(ubyte)[]) std.file.read(tgz));

  auto body = publishBody("@xurp/manual", "0.0.4", `,"stable":"0.0.4"`, encoded);
  auto result = installPublishedPackument(work ~ "/npm", "@xurp/manual",
      cast(const(ubyte)[]) body, "https://cdn.example.com/npm");

  assert(result.name == "@xurp/manual");
  assert(result.ver == "0.0.4");
  assert(exists(work ~ "/npm/xurp/manual/0.0.4/manual-0.0.4.tgz"));
  auto doc = parseJSON(readText(work ~ "/npm/@xurp/manual"));
  assert(doc["dist-tags"]["latest"].str == "0.0.4");
  assert(doc["dist-tags"]["stable"].str == "0.0.4", "custom tag must come from the publish body");
  assert(doc["versions"]["0.0.4"]["dist"]["tarball"].str
      == "https://cdn.example.com/npm/@xurp/manual/-/manual-0.0.4.tgz");
}

@("installPublishedPackument installs a prerelease with its channel tag")
unittest {
  auto work = tempBase();
  scope (exit)
    if (exists(work))
      rmdirRecurse(work);
  auto tgz = makeTgz(work ~ "/src", `{"name":"lib","version":"1.0.0-dev.1"}`);
  auto encoded = cast(string) Base64.encode(cast(const(ubyte)[]) std.file.read(tgz));

  auto result = installPublishedPackument(work ~ "/npm", "lib",
      cast(const(ubyte)[]) publishBody("lib", "1.0.0-dev.1", "", encoded), "http://cdn/npm");
  assert(result.ver == "1.0.0-dev.1");
  auto doc = parseJSON(readText(work ~ "/npm/lib"));
  assert(doc["dist-tags"]["dev"].str == "1.0.0-dev.1");
  assert(doc["dist-tags"]["latest"].str == "1.0.0-dev.1", "latest falls back to the only version");
}

@("installPublishedPackument keeps a channel tag requested for a release version")
unittest {
  auto work = tempBase();
  scope (exit)
    if (exists(work))
      rmdirRecurse(work);
  auto tgz = makeTgz(work ~ "/src", `{"name":"lib","version":"2.0.0"}`);
  auto encoded = cast(string) Base64.encode(cast(const(ubyte)[]) std.file.read(tgz));

  // 2.0.0 本身不属于任何通道，`--tag dev` 就该把 dev 指向它（由 refreshPackument 推导不出来）
  auto body = publishBody("lib", "2.0.0", `,"dev":"2.0.0"`, encoded);
  installPublishedPackument(work ~ "/npm", "lib", cast(const(ubyte)[]) body, "http://cdn/npm");
  auto doc = parseJSON(readText(work ~ "/npm/lib"));
  assert(doc["dist-tags"]["dev"].str == "2.0.0", "channel tag of a release must survive");
  assert(doc["dist-tags"]["latest"].str == "2.0.0");
}

@("installPublishedPackument rejects mismatched names and malformed bodies")
unittest {
  auto work = tempBase();
  scope (exit)
    if (exists(work))
      rmdirRecurse(work);
  auto tgz = makeTgz(work ~ "/src", `{"name":"lib","version":"1.0.0"}`);
  auto encoded = cast(string) Base64.encode(cast(const(ubyte)[]) std.file.read(tgz));
  auto good = publishBody("lib", "1.0.0", "", encoded);

  // 请求体 name 与 URI 路径不一致
  assertThrown(installPublishedPackument(work ~ "/npm", "@other/pkg",
      cast(const(ubyte)[]) good, "http://cdn/npm"));
  // 不是合法 JSON
  assertThrown(installPublishedPackument(work ~ "/npm", "lib",
      cast(const(ubyte)[]) "not json", "http://cdn/npm"));
  // 缺少 _attachments
  assertThrown(installPublishedPackument(work ~ "/npm", "lib",
      cast(const(ubyte)[]) `{"name":"lib","versions":{"1.0.0":{}}}`, "http://cdn/npm"));
  // 附件 data 不是合法 Base64
  assertThrown(installPublishedPackument(work ~ "/npm", "lib",
      cast(const(ubyte)[]) publishBody("lib", "1.0.0", "", "!!!!"), "http://cdn/npm"));
}
