/* Copyright (C) 2026 Beangle
 */

module test.micdn.resolve_test;

import std.file;
import std.path : buildPath, dirName;

import micdn.config : parse;
import micdn.model;
import micdn.resolve;

@("isValidGav accepts group:artifact:version")
unittest {
  assert(isValidGav("org.webjars:bootstrap:4.6.1"));
  assert(!isValidGav("bad-gav"));
  assert(!isValidGav("a:b"));
  assert(!isValidGav(":a:b:1"));
}

@("resolveMicdn rejects missing dir and invalid gav")
unittest {
  auto home = buildPath(tempDir, "micdn-resolve-providers");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);

  auto src = buildPath(home, "src");
  mkdirRecurse(src);

  auto xml = `<?xml version="1.0"?><micdn home="` ~ home ~ `">
  <maven base="` ~ home ~ `/maven"/>
  <npm base="` ~ home ~ `/npm"/>
  <static base="` ~ home ~ `/static">
    <bundle name="badjar">
      <jar gav="not-a-gav"/>
    </bundle>
    <bundle name="nodir">
      <dir location="` ~ home ~ `/missing"/>
    </bundle>
    <bundle name="okdir">
      <dir location="` ~ src ~ `"/>
    </bundle>
  </static>
</micdn>`;
  auto config = parse(home, xml);
  assert(!resolveMicdn(config));

  auto xml2 = `<?xml version="1.0"?><micdn home="` ~ home ~ `">
  <maven base="` ~ home ~ `/maven"/>
  <npm base="` ~ home ~ `/npm"/>
  <static base="` ~ home ~ `/static">
    <bundle name="boot">
      <dir location="` ~ src ~ `"/>
    </bundle>
  </static>
</micdn>`;
  config = parse(home, xml2);
  assert(resolveMicdn(config));
}
