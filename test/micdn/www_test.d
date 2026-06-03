/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.www_test;

import std.algorithm : endsWith;
import std.conv : octal;
import std.file;
import std.path : buildPath;
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

@("mountDoc links dir and leaves tree writable")
unittest {
  auto home = buildPath(tempDir, "micdn-www-mount");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto src = buildPath(home, "src", "manual");
  mkdirRecurse(src);
  write(buildPath(src, "index.html"), "ok");

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="manual" dir="` ~ src ~ `" />
  </www>
</micdn>`;
  auto config = parse(home, xml);
  assert(WwwRepo.mountDoc(config, config.www.docs[0]));
  auto repo = new WwwRepo(config.www.base);
  assert(repo.get("/manual/index.html") !is null);
  auto attrs = getAttributes(repo.get("/manual/index.html"));
  assert((attrs & octal!200) != 0, "mounted files should stay writable");
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

  auto dummy = new DirProvider("/tmp");
  auto doc = new WwwDocConfig("m/edu/learning", dummy, "index.html");
  auto repo = new WwwRepo(tmp, [doc]);

  assert(repo.get("/m/edu/learning/app.js") !is null);
  assert(repo.get("/m/edu/learning/app.js").endsWith("app.js"));
  assert(repo.get("/m/edu/learning/route/foo") !is null);
  assert(repo.get("/m/edu/learning/route/foo").endsWith("index.html"));
  assert(repo.get("/other/route") is null);
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

  auto dummy = new DirProvider("/tmp");
  auto docs = [
    new WwwDocConfig("a", dummy, "index.html"),
    new WwwDocConfig("a/b", dummy, "index.html"),
  ];
  auto repo = new WwwRepo(tmp, docs);

  assert(repo.get("/a/b/x").endsWith(buildPath("a", "b", "index.html")));
  assert(repo.get("/a/x").endsWith(buildPath("a", "index.html")));
}
