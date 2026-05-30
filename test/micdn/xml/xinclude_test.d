/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.xml.xinclude_test;

import std.exception;
import std.file;
import std.path;
import std.string;
import std.uuid;

import dxml.dom;

import micdn.config : parseFile;
import micdn.xml : MicdnXmlException, expandXiIncludes, parseDomRoot, readXml;

@("expandXiIncludes replaces self-closing xi:include")
unittest {
  string dir = buildPath(tempDir(), "micdn-xi-u1-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit)
    rmdirRecurse(dir);

  write(buildPath(dir, "part.xml"), `<?xml version="1.0"?><inner id="1"/>`);
  string expanded = expandXiIncludes(dir, `<root><xi:include href="part.xml"/></root>`);
  assert(expanded.indexOf(`<inner id="1"/>`) >= 0);
  assert(expanded.indexOf("xi:include") < 0);
}

@("readXml resolves nested includes")
unittest {
  string dir = buildPath(tempDir(), "micdn-xi-u2-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit)
    rmdirRecurse(dir);

  write(buildPath(dir, "leaf.xml"), `<leaf/>`);
  write(buildPath(dir, "mid.xml"), `<mid><xi:include href="leaf.xml"/></mid>`);
  write(buildPath(dir, "root.xml"), `<root><xi:include href="mid.xml"/></root>`);

  string all = readXml(buildPath(dir, "root.xml"));
  assert(all.indexOf("<leaf/>") >= 0);
  assert(all.indexOf("<mid>") >= 0);
}

@("expanded XML parses with dxml")
unittest {
  string dir = buildPath(tempDir(), "micdn-xi-u3-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit)
    rmdirRecurse(dir);

  write(buildPath(dir, "child.xml"), `<child/>`);
  string merged = expandXiIncludes(dir, `<a><xi:include href="child.xml"/></a>`);
  auto dom = parseDOM!simpleXML(merged).children[0];
  assert(dom.name == "a");
  assert(dom.children.length == 1);
  assert(dom.children[0].name == "child");
}

@("readXml + micdn.config.parseFile blob fragment")
unittest {
  string dir = buildPath(tempDir(), "micdn-xi-u4-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit)
    rmdirRecurse(dir);

  write(buildPath(dir, "blob.xml"),
      `<blob base="/tmp/b">
  <bucket name="x" key="secret-key"/>
</blob>`);
  write(buildPath(dir, "micdn.xml"), `<?xml version="1.0" encoding="UTF-8"?>
<micdn xmlns:xi="http://www.w3.org/2001/XInclude">
  <xi:include href="blob.xml"/>
  <maven/>
  <npm/>
</micdn>`);

  auto cfg = parseFile(buildPath(dir, "micdn.xml"));
  assert(cfg.blob !is null);
  assert(cfg.blob.base == "/tmp/b");
  assert(cfg.blob.buckets.length == 1);
  assert(cfg.blob.buckets[0].name == "x");
  assert(cfg.blob.buckets[0].publicImages);
}

@("xi:include rejects .. in href")
unittest {
  string dir = buildPath(tempDir(), "micdn-xi-u5-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit)
    rmdirRecurse(dir);

  assertThrown!MicdnXmlException(expandXiIncludes(dir, `<x><xi:include href="../evil.xml"/></x>`));
}

@("parseDomRoot reports invalid XML with line context")
unittest {
  import std.exception;

  auto bad = "<micdn>\n  <static>\n  </micdn>";
  auto e = collectException!MicdnXmlException(parseDomRoot(bad, "/tmp/micdn.xml"));
  assert(e !is null);
  assert(e.msg.indexOf("/tmp/micdn.xml") >= 0);
  assert(e.msg.indexOf("[") >= 0);
  assert(e.msg.indexOf("near:") >= 0);
}

@("parse rejects stray text in element body")
unittest {
  import std.exception;

  import micdn.config : parse;

  auto xml = `<?xml version="1.0"?><micdn><www>
-  </www></micdn>`;
  auto e = collectException!MicdnXmlException(parse("/tmp", xml, "/tmp/micdn.xml"));
  assert(e !is null);
  assert(e.msg.indexOf("unexpected text") >= 0);
  assert(e.msg.indexOf("/tmp/micdn.xml") >= 0);
  assert(e.msg.indexOf("near:") >= 0);
}
