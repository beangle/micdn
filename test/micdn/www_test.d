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

  auto repo = new WwwRepo(tmp);
  assert(repo.get("/manual/a.html") == resolveRepositoryPath(tmp, decodeRepositoryUri("/manual/a.html")));
  assert(repo.get("/manual/missing.html") is null);
  assert(repo.get("/other/x") is null);
  assert(repo.get("/manual/../etc/passwd") is null);
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
  assert(repo.get(decodeRepositoryUri("/%2e%2e%2fsecret.txt")) is null);
  assert(repo.get(decodeRepositoryUri("/%5cWindows%5cwin.ini")) is null);
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

  assert(repo.get("/app/route/foo") !is null);
  assert(repo.get("/app/route/foo").endsWith("index.html"));
  assert(repo.get("/app/assets/ok.js") !is null);
  assert(repo.get("/app/assets/missing.js") is null);
  assert(repo.get("/app/missing.css") is null);
  assert(repo.get("/app/missing.woff2") is null);
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

  assert(repo.get("/m/edu/learning/app.js") !is null);
  assert(repo.get("/m/edu/learning/app.js").endsWith("app.js"));
  assert(repo.get("/m/edu/learning/route/foo") !is null);
  assert(repo.get("/m/edu/learning/route/foo").endsWith("index.html"));
  assert(repo.get("/other/route") is null);
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

  assert(repo.get("/m/edu/teaching") !is null);
  assert(repo.get("/m/edu/teaching/a/bc") !is null);
  assert(repo.get("/m/edu/teaching/a/bc").endsWith("index.html"));
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

  assert(repo.get("/app/route/foo").endsWith("index.html"));
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
  assert(repo.get("/spa/deep/link").endsWith("index.html"));
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

  assert(repo.get("/a/b/x").endsWith(buildPath("a", "b", "index.html")));
  assert(repo.get("/a/x").endsWith(buildPath("a", "index.html")));
}
