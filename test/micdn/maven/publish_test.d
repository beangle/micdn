/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.maven.publish_test;

import std.exception : assertThrown;
import std.file;
import std.path : buildPath;
import std.uuid : randomUUID;

import micdn.maven.publish : storeUpload;

private string tempBase() {
  auto dir = buildPath(tempDir(), "micdn_maven_publish_" ~ randomUUID().toString());
  mkdirRecurse(dir);
  return dir;
}

@("storeUpload writes the uploaded artifact under the repository root")
unittest {
  auto work = tempBase();
  scope (exit)
    if (exists(work))
      rmdirRecurse(work);

  auto ruri = "/org/beangle/tool/1.0.0-SNAPSHOT/tool-1.0.0-20250101.120000-1.jar";
  auto path = storeUpload(work, ruri, cast(const(ubyte)[]) "jar-bytes");
  assert(path == work ~ ruri);
  assert(readText(path) == "jar-bytes");
  // 临时文件不能残留
  assert(!exists(path ~ ".incoming"));
  // 覆盖上传（同一路径重复 deploy）
  assert(storeUpload(work, ruri, cast(const(ubyte)[]) "second") == path);
  assert(readText(path) == "second");
}

@("storeUpload rejects directories and dot segments")
unittest {
  auto work = tempBase();
  scope (exit)
    if (exists(work))
      rmdirRecurse(work);

  assertThrown(storeUpload(work, "/", cast(const(ubyte)[]) "x"));
  assertThrown(storeUpload(work, "/a/b/", cast(const(ubyte)[]) "x"));
  assertThrown(storeUpload(work, "/a/../b.jar", cast(const(ubyte)[]) "x"));
  assertThrown(storeUpload(work, "/a/./b.jar", cast(const(ubyte)[]) "x"));
  assertThrown(storeUpload(work, "", cast(const(ubyte)[]) "x"));
}
