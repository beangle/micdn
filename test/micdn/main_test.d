/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.main_test;

import std.file;
import std.path : buildPath;

import micdn.asset : AssetRepo;
import micdn.config : parseFile;
import micdn.main : runClean;

@("clean removes www/static deploy dirs but keeps maven/npm caches and blob")
unittest {
  auto home = buildPath(tempDir, "micdn-clean-all");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto maven = buildPath(home, "m2");
  auto npm = buildPath(home, "npm");
  auto www = buildPath(home, "www");
  auto asset = buildPath(home, "static");
  mkdirRecurse(buildPath(maven, "org"));
  mkdirRecurse(buildPath(npm, "pkg"));
  mkdirRecurse(buildPath(www, "manual"));
  mkdirRecurse(buildPath(asset, "bui"));
  auto xmlPath = buildPath(home, "micdn.xml");
  write(xmlPath, `<?xml version="1.0"?><micdn>
  <maven base="` ~ maven ~ `"/>
  <npm base="` ~ npm ~ `"/>
  <static base="` ~ asset ~ `"/>
  <www base="` ~ www ~ `"/>
</micdn>`);

  auto rc = runClean(["-f", xmlPath, "clean", "--yes"]);
  assert(rc == 0, "clean must succeed");
  assert(!exists(www) && !exists(asset), "www/static deploy dirs must be removed");
  assert(exists(maven) && exists(npm), "maven/npm download caches must be kept");
}

@("clean without www/static removes nothing and keeps maven/npm/blob")
unittest {
  auto home = buildPath(tempDir, "micdn-clean-blob");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto maven = buildPath(home, "m2");
  auto blob = buildPath(home, "blob");
  mkdirRecurse(buildPath(maven, "x"));
  mkdirRecurse(buildPath(blob, "obj"));
  auto xmlPath = buildPath(home, "micdn.xml");
  write(xmlPath, `<?xml version="1.0"?><micdn>
  <maven base="` ~ maven ~ `"/>
  <npm/>
  <blob base="` ~ blob ~ `">
    <bucket name="b" key="k"/>
  </blob>
</micdn>`);

  auto rc = runClean(["-f", xmlPath, "clean", "--yes"]);
  assert(rc == 0, "clean must succeed without www/static sections");
  assert(exists(maven), "maven cache must be kept");
  assert(exists(blob), "blob data must be kept");
  auto www = buildPath(home, "www");
  assert(!exists(www), "www base must not be created by clean");
}

@("clean keeps blob data and tolerates absent deploy dirs")
unittest {
  auto home = buildPath(tempDir, "micdn-clean-absent");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto maven = buildPath(home, "m2");
  auto blob = buildPath(home, "blob");
  mkdirRecurse(buildPath(blob, "obj"));
  auto xmlPath = buildPath(home, "micdn.xml");
  write(xmlPath, `<?xml version="1.0"?><micdn>
  <maven base="` ~ maven ~ `"/>
  <npm/>
  <blob base="` ~ blob ~ `">
    <bucket name="b" key="k"/>
  </blob>
  <www base="` ~ buildPath(home, "www") ~ `"/>
  <static base="` ~ buildPath(home, "static") ~ `"/>
</micdn>`);

  auto rc = runClean(["-f", xmlPath, "clean", "--yes"]);
  assert(rc == 0, "clean must succeed with absent deploy dirs");
  assert(exists(blob), "blob data must not be cleaned");
}

@("clean removes dir bundle symlink but keeps real source files")
unittest {
  auto home = absolutePath(buildPath(tempDir, "micdn-clean-dir-bundle"));
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto srcDir = buildPath(home, "src");
  mkdirRecurse(buildPath(srcDir, "sub"));
  auto realFile = buildPath(srcDir, "sub", "a.js");
  write(realFile, "var a = 1;");
  auto assetBase = buildPath(home, "static");
  auto xmlPath = buildPath(home, "micdn.xml");
  write(xmlPath, `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <static base="` ~ assetBase ~ `">
    <bundle name="local"><dir location="` ~ srcDir ~ `"/></bundle>
  </static>
</micdn>`);

  AssetRepo.build(parseFile(xmlPath));
  auto linkPath = buildPath(assetBase, "local");
  assert(isSymlink(linkPath), "dir bundle must be deployed as a symlink");

  auto rc = runClean(["-f", xmlPath, "clean", "--yes"]);
  assert(rc == 0, "clean must succeed");
  assert(!exists(assetBase), "clean must remove the asset deploy dir");
  assert(!exists(linkPath), "clean must remove the dir bundle symlink");
  assert(exists(realFile), "clean must not delete real files behind dir bundle");
}
