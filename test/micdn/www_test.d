/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.www_test;

import std.algorithm : endsWith;
import std.file;
import std.path : buildPath, dirName;
import std.zip : ArchiveMember, ZipArchive;
import micdn.config : parse;
import micdn.model;
import micdn.web;
import micdn.www;

@("WwwRepo maps http path under base")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-test");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "manual"));
  auto html = buildPath(tmp, "manual", "a.html");
  write(html, "<html></html>");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto repo = new WwwRepo(tmp, [new WwwDocConfig("manual", dummy)]);
  assert(repo.get("/manual/a.html").path == resolveRepositoryPath(tmp, decodeRepositoryUri("/manual/a.html")));
  assert(repo.get("/manual/missing.html").path is null);
  assert(repo.get("/other/x").path is null);
  assert(repo.get("/manual/../etc/passwd").path is null);
}

@("WwwRepo does not serve files outside any doc")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-nodoc");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "manual"));
  write(buildPath(tmp, "manual", "a.html"), "ok");
  write(buildPath(tmp, "loose.txt"), "loose");

  auto repo = new WwwRepo(tmp);
  assert(repo.get("/manual/a.html").path is null);
  assert(repo.get("/loose.txt").path is null);
}

@("WwwDocTree finds longest doc prefix and falls back on broken chain")
unittest {
  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto docA = new WwwDocConfig("a", dummy);
  auto docAB = new WwwDocConfig("a/b", dummy);
  auto docXYZ = new WwwDocConfig("x/y/z", dummy);
  auto tree = new WwwDocTree([docA, docAB, docXYZ]);

  assert(tree.find(["a"]) is docA);
  assert(tree.find(["a", "b"]) is docAB);
  assert(tree.find(["a", "b", "c"]) is docAB);
  assert(tree.find(["a", "c"]) is docA);
  assert(tree.find(["x", "y", "z"]) is docXYZ);
  assert(tree.find(["x", "y"]) is null);
  assert(tree.find(["x"]) is null);
  assert(tree.find(["other"]) is null);
  assert(tree.find([]) is null);
}

@("WwwDocTree empty tree matches nothing")
unittest {
  auto tree = new WwwDocTree(null);
  assert(tree.find(["a"]) is null);
  assert(tree.find([]) is null);
}

@("WwwDocTree falls back to doc above doc-less intermediate node")
unittest {
  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto docA = new WwwDocConfig("a", dummy);
  auto docABC = new WwwDocConfig("a/b/c", dummy);
  auto tree = new WwwDocTree([docA, docABC]);

  assert(tree.find(["a", "b", "x"]) is docA);
  assert(tree.find(["a", "b"]) is docA);
  assert(tree.find(["a"]) is docA);
  assert(tree.find(["a", "b", "c"]) is docABC);
  assert(tree.find(["a", "b", "c", "d"]) is docABC);
  assert(tree.find(["x"]) is null);
}

@("WwwDocTree rejects duplicate doc endpoint")
unittest {
  import std.exception;

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  assertThrown!Exception(new WwwDocTree([
    new WwwDocConfig("a", dummy),
    new WwwDocConfig("a", dummy),
  ]));
}

@("WwwRepo rejects encoded traversal")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-safe");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "manual"));
  write(buildPath(tmp, "manual", "a.html"), "ok");
  write(buildPath(tmp, "secret.txt"), "secret");

  auto repo = new WwwRepo(tmp);
  assert(repo.get(decodeRepositoryUri("/%2e%2e%2fsecret.txt")).path is null);
  assert(repo.get(decodeRepositoryUri("/%5cWindows%5cwin.ini")).path is null);
}

@("WwwRepo try-file skips fallback for missing static assets")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-tryfile-static");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  auto docRoot = buildPath(tmp, "app");
  mkdirRecurse(buildPath(docRoot, "assets"));
  write(buildPath(docRoot, "index.html"), "spa");
  write(buildPath(docRoot, "assets", "ok.js"), "js");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto doc = new WwwDocConfig("app", dummy, "index.html");
  auto repo = new WwwRepo(tmp, [doc]);

  assert(repo.get("/app/route/foo").path !is null);
  assert(repo.get("/app/route/foo").path.endsWith("index.html"));
  assert(repo.get("/app/assets/ok.js").path !is null);
  assert(repo.get("/app/assets/missing.js").path is null);
  assert(repo.get("/app/missing.css").path is null);
  assert(repo.get("/app/missing.woff2").path is null);
}

@("WwwRepo try-file falls back for spa deep link")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-tryfile");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  auto docRoot = buildPath(tmp, "m", "edu", "learning");
  mkdirRecurse(docRoot);
  write(buildPath(docRoot, "index.html"), "spa");
  write(buildPath(docRoot, "app.js"), "js");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto doc = new WwwDocConfig("m/edu/learning", dummy, "index.html");
  auto repo = new WwwRepo(tmp, [doc]);

  assert(repo.get("/m/edu/learning/app.js").path !is null);
  assert(repo.get("/m/edu/learning/app.js").path.endsWith("app.js"));
  assert(repo.get("/m/edu/learning/route/foo").path !is null);
  assert(repo.get("/m/edu/learning/route/foo").path.endsWith("index.html"));
  assert(repo.get("/other/route").path is null);
}

@("WwwRepo try-file falls back for m/edu/teaching deep link")
unittest {
  auto home = buildPath(tempDir, "micdn-www-teaching");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto zipPath = buildPath(home, "teaching.zip");
  mkdirRecurse(dirName(zipPath));
  auto m = new ArchiveMember();
  m.name = "index.html";
  m.expandedData(cast(ubyte[]) "spa");
  auto z = new ZipArchive();
  z.addMember(m);
  write(zipPath, z.build());

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="m/edu/teaching" zip="` ~ zipPath ~ `" try-file="index.html" />
  </www>
</micdn>`;
  auto config = parse(home, xml);
  auto repo = WwwRepo.build(config);

  assert(repo.get("/m/edu/teaching").path !is null);
  assert(repo.get("/m/edu/teaching/a/bc").path !is null);
  assert(repo.get("/m/edu/teaching/a/bc").path.endsWith("index.html"));
}

@("WwwRepo try-file returns path without runtime exists check")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-tryfile-missing");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "app"));

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto doc = new WwwDocConfig("app", dummy, "index.html");
  auto repo = new WwwRepo(tmp, [doc]);

  assert(repo.get("/app/route/foo").path.endsWith("index.html"));
}

@("deployDoc warns when try-file missing after mount")
unittest {
  auto home = buildPath(tempDir, "micdn-www-tryfile-mount-warn");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto zipPath = buildPath(home, "spa.zip");
  mkdirRecurse(dirName(zipPath));
  auto m = new ArchiveMember();
  m.name = "app.js";
  m.expandedData(cast(ubyte[]) "js");
  auto z = new ZipArchive();
  z.addMember(m);
  write(zipPath, z.build());

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="spa" zip="` ~ zipPath ~ `" try-file="index.html" />
  </www>
</micdn>`;
  auto config = parse(home, xml);
  assert(cast(ZipProvider) config.www.docs[0].provider !is null);
  assert(WwwRepo.deployDoc(config, config.www.docs[0]));
  auto repo = new WwwRepo(config.www.base, config.www.docs);
  assert(repo.get("/spa/deep/link").path.endsWith("index.html"));
}

@("WwwRepo try-file uses longest doc prefix")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-tryfile-prefix");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "a"));
  mkdirRecurse(buildPath(tmp, "a", "b"));
  write(buildPath(tmp, "a", "index.html"), "a");
  write(buildPath(tmp, "a", "b", "index.html"), "ab");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto docs = [
    new WwwDocConfig("a", dummy, "index.html"),
    new WwwDocConfig("a/b", dummy, "index.html"),
  ];
  auto repo = new WwwRepo(tmp, docs);

  assert(repo.get("/a/b/x").path.endsWith(buildPath("a", "b", "index.html")));
  assert(repo.get("/a/x").path.endsWith(buildPath("a", "index.html")));
}

@("WwwRepo get carries matched doc with auto-gzip flag")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-autogzip");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "app"));
  write(buildPath(tmp, "app", "index.html"), "spa");
  mkdirRecurse(buildPath(tmp, "plain"));
  write(buildPath(tmp, "plain", "index.html"), "plain");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto repo = new WwwRepo(tmp, [
    new WwwDocConfig("app", dummy, "index.html", false, false),
    new WwwDocConfig("plain", dummy),
  ]);
  auto hit = repo.get("/app/route");
  assert(hit.path.endsWith("index.html"));
  assert(hit.doc.autoGzip == false);
  assert(repo.get("/plain/").doc.autoGzip == true);
  assert(repo.get("/missing").path is null);
}

@("WwwRepo get keeps matched doc on missing file")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-missdoc");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "app"));

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto doc = new WwwDocConfig("app", dummy);
  auto repo = new WwwRepo(tmp, [doc]);

  auto miss = repo.get("/app/route/x");
  assert(miss.path is null);
  assert(miss.doc is doc);
  assert(repo.get("/other/x").doc is null);
}
