/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.www_test;

import std.file;
import std.path : buildPath;

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
