/* Copyright (C) 2023 Beangle
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

module micdn.config_test;

import std.algorithm : canFind;
import std.exception;
import std.file;
import std.path;

import micdn.config;
import micdn.model;
import micdn.resolve;
import micdn.web : normalizeBasePath;
import micdn.xml;

auto CentralURL = "https://repo1.maven.org/maven2";

@("default maven/npm repo bases expand tilde")
unittest {
  assert(MavenRepoConfig.defaultConfig().base == expandTilde("~/maven"));
  assert(NpmRepoConfig.defaultConfig().base == expandTilde("~/npm"));
}

@("asset repo remote url")
unittest{
  auto repo = new MavenRepoConfig("~/maven", ["https://repo1.maven.org/maven2"]);
  auto remoteBui = "https://repo1.maven.org/maven2/org/beangle/bundles/beangle-bundles-bui/0.1.7/beangle-bundles-bui-0.1.7.jar";
  assert(remoteBui == repo.remoteUrls("org.beangle.bundles:beangle-bundles-bui:0.1.7")[0]);
}

@("asset Repository config parse")
unittest {
  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <static base="~/tmp/static">
    <bundle name="urp">
      <dir location="~/.openurp/static"/>
    </bundle>
    <bundle name="my97">
      <jar gav="org.beangle.bundles:beangle-bundles-my97:4.8"/>
    </bundle>

    <bundle name="bui">
      <jar gav="org.beangle.bundles:beangle-bundles-bui:0.1.7"/>
      <jar gav="org.beangle.bundles:beangle-bundles-bui:0.1.4"/>
      <jar gav="org.beangle.bundles:beangle-bundles-bui:0.2.0"/>
      <jar gav="org.beangle.bundles:beangle-bundles-bui:0.2.1"/>
    </bundle>
  </static>
</micdn>`;

  auto dom = parseXml(content);
  auto config = parseAsset("~/tmp", dom);
  assert(config.base == expandTilde("~/tmp/static"));
}

@("static bundle rejects dir mixed with jar")
unittest {
  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <static base="~/tmp/static">
    <bundle name="bad">
      <dir location="~/x"/>
      <jar gav="a:b:1"/>
    </bundle>
  </static>
</micdn>`;
  auto dom = parseXml(content);
  assertThrown(parseAsset("~/tmp", dom));
}

@("static bundle rejects dir mixed with npm")
unittest {
  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <static base="~/tmp/static">
    <bundle name="bad">
      <dir location="~/x"/>
      <npm package="foo@1.0.0"/>
    </bundle>
  </static>
</micdn>`;
  auto dom = parseXml(content);
  assertThrown(parseAsset("~/tmp", dom));
}

@("maven config parse remotes")
unittest
{
    auto content = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <repo>
    <remote url="https://maven.aliyun.com/nexus/content/groups/public"/>
    <remote url="https://repo1.maven.org/maven2"/>
  </repo>
</micdn>`;

  auto dom = parseXml(content);
  auto config = parseMaven("~/maven", dom);
  assert(config.remotes.length == 2);
  assert(config.remotes[1] == CentralURL);
}

@("blob config parse xml")
unittest {
  auto content = `<?xml version="1.0"?>
<micdn>
  <blob base="/tmp/blob" maxSize="10G">
    <bucket name="local" key="test-key-123"/>
    <bucket name="closed" key="k2" publicImages="false"/>
  </blob>
</micdn>
`;
  auto dom = parseXml(content);
  auto config = parseBlob("~/tmp", dom);
  assert(config.base == "/tmp/blob");
  assert(config.buckets.length == 2);
  assert(config.buckets[0].name == "local");
  assert(config.buckets[0].key == "test-key-123");
  assert(config.buckets[0].publicImages);
  assert(config.buckets[1].name == "closed");
  assert(!config.buckets[1].publicImages);
  assert(config.maxSize == 10L * 1024 * 1024 * 1024);
  assert(10L * 1024 * 1024 * 1024 == parseSize("10g"));
}


@("normalizeEndpoint and isValidEndpoint")
unittest {
  assert(normalizeEndpoint("") == "");
  assert(normalizeEndpoint(null) == "");
  assert(normalizeEndpoint("/") == "");
  assert(normalizeEndpoint("  ") == "");
  assert(normalizeEndpoint("static") == "/static");
  assert(normalizeEndpoint("/static") == "/static");
  assert(normalizeEndpoint("/static/") == "/static");
  assert(normalizeEndpoint("  /static/  ") == "/static");

  assert(!isValidEndpoint(""));
  assert(isValidEndpoint("/static"));
  assert(isValidEndpoint("/maven"));
  assert(!isValidEndpoint("/"));
  assert(!isValidEndpoint("/static/"));
  assert(!isValidEndpoint("static"));

  assert(isValidEndpoint(normalizeEndpoint("/maven")));
  assert(isValidEndpoint(normalizeEndpoint("/static/")));
  assert(isValidEndpoint(normalizeEndpoint("asset")));
  assert(isValidEndpoint(normalizeEndpoint("/manual/")));
}

@("www doc parses try-file attribute")
unittest {
  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="m/edu/learning" zip="~/docs/spa.zip" try-file="index.html" />
  </www>
</micdn>`;
  auto config = parse("~/tmp", xml);
  assert(config.www.docs[0].tryFile == "index.html");
}

@("www doc defaults try-file to index.html")
unittest {
  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="manual" zip="~/docs/spa.zip" />
  </www>
</micdn>`;
  auto config = parse("~/tmp", xml);
  assert(config.www.docs[0].tryFile == "index.html");
}

@("www doc rejects unsafe try-file")
unittest {
  import std.exception;

  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="manual" zip="~/m.zip" try-file="../secret.html" />
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", xml));
}

@("www doc rejects try-file with path separator")
unittest {
  import std.exception;

  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="manual" zip="~/m.zip" try-file="fallback/index.html" />
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", xml));
}

@("www doc parses npm zip attributes")
unittest {
  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="manual" npm="@xurp/manual@0.0.2" />
    <doc name="zipdoc" zip="~/docs/pkg.zip" inner="dist" />
  </www>
</micdn>`;
  auto config = parse("~/tmp", xml);
  assert(config.www.docs.length == 2);
  assert(cast(NpmProvider) config.www.docs[0].provider !is null);
  assert(cast(ZipProvider) config.www.docs[1].provider !is null);
  assert((cast(NpmProvider) config.www.docs[0].provider).dir == "dist");
  assert((cast(ZipProvider) config.www.docs[1].provider).dir == "dist");
}

@("www doc rejects duplicate name")
unittest {
  import std.exception;

  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="manual" zip="~/a.zip" />
    <doc name="manual/" zip="~/b.zip" />
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", xml));
}

@("www doc rejects dir attribute")
unittest {
  import std.exception;

  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="local" dir="~/docs/local" />
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", xml));
}

@("www doc parses auto-deploy on zip")
unittest {
  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="zipdoc" zip="~/docs/pkg.zip" inner="dist" auto-deploy="true" />
  </www>
</micdn>`;
  auto config = parse("~/tmp", xml);
  assert(config.www.docs.length == 1);
  assert(config.www.docs[0].autoDeploy);
  assert(cast(ZipProvider) config.www.docs[0].provider !is null);
}

@("www doc parses and round-trips auto-gzip")
unittest {
  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="on" zip="~/a.zip" />
    <doc name="off" zip="~/b.zip" auto-gzip="false" />
  </www>
</micdn>`;
  auto config = parse("~/tmp", xml);
  assert(config.www.docs.length == 2);
  assert(config.www.docs[0].autoGzip == true);
  assert(config.www.docs[1].autoGzip == false);

  auto xml2 = config.toXml();
  assert(xml2.canFind(`auto-gzip="false"`));
  assert(!xml2.canFind(`auto-gzip="true"`));

  auto config2 = parse("~/tmp", xml2);
  assert(config2.www.docs[0].autoGzip == true);
  assert(config2.www.docs[1].autoGzip == false);
}

@("www doc rejects auto-deploy without zip")
unittest {
  import std.exception;

  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="manual" npm="~/m" auto-deploy="true" />
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", xml));
}

@("www doc rejects multiple source attributes")
unittest {
  import std.exception;

  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="manual" npm="@a/b@1" zip="~/m.zip"/>
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", xml));
}

@("www doc rejects name with .. segments")
unittest {
  import std.exception;

  auto traversal = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <npm/>
  <www base="~/tmp/www">
    <doc name="manual/../admin" zip="~/m.zip"/>
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", traversal));
}

@("www doc rejects empty name")
unittest {
  import std.exception;

  auto emptyLoc = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <npm/>
  <www base="~/tmp/www">
    <doc name="/" zip="~/m.zip"/>
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", emptyLoc));

  auto missingLoc = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <npm/>
  <www base="~/tmp/www">
    <doc zip="~/m.zip"/>
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", missingLoc));
}

@("normalizeDocName and isValidDocName")
unittest {
  assert(normalizeDocName("manual") == "manual");
  assert(normalizeDocName("a/b") == "a/b");
  assert(normalizeDocName("  a/b/  ") == "a/b");
  assert(isValidDocName("manual"));
  assert(isValidDocName("a/b"));
  assert(!isValidDocName(""));
  assert(!isValidDocName("/manual"));
  assert(!isValidDocName("manual/"));
  assert(!isValidDocName("a/../b"));
  auto doc = new WwwDocConfig("a/b", new ZipProvider("/tmp/x.zip", ""));
  assert(doc.endpoint() == "/a/b");
}

@("endpoint conflict validation")
unittest {
  import std.exception;

  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <npm/>
  <static base="~/tmp/static">
    <bundle name="x"><dir location="~/x"/></bundle>
  </static>
  <www base="~/tmp/www">
    <doc name="admin" zip="~/manual.zip"/>
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", content));

  auto ok = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <npm/>
  <static base="~/tmp/static">
    <bundle name="x"><dir location="~/x"/></bundle>
  </static>
  <www base="~/tmp/www">
    <doc name="manual" zip="~/manual.zip"/>
  </www>
</micdn>`;
  auto config = parse("~/tmp", ok);
  assert(config.www.docs[0].name == "manual");
  assert(config.www.docs[0].endpoint() == "/manual");
}

@("endpoint conflict: prefix and multiple scenarios")
unittest {
  import std.exception;

  // 1. 内置 /maven 与 www doc location="/maven" 冲突
  auto mavenPrefix = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <npm/>
  <static base="~/tmp/static">
    <bundle name="x"><dir location="~/x"/></bundle>
  </static>
  <www base="~/tmp/www">
    <doc name="maven" zip="~/m.zip"/>
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", mavenPrefix),
      "fixed mount vs www doc conflict");

  // 2. 内置 /blob 与 www doc location="/blob" 冲突（启用 blob 时）
  auto staticBlob = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <npm/>
  <static base="~/tmp/static">
    <bundle name="x"><dir location="~/x"/></bundle>
  </static>
  <blob base="~/tmp/blob">
    <bucket name="b" key="k"/>
  </blob>
  <www base="~/tmp/www">
    <doc name="blob" zip="~/m.zip"/>
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", staticBlob),
      "blob mount vs www doc conflict");

  // 3. 两个 www doc: /doc 与 /doc/guide 冲突
  auto wwwPrefix = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <npm/>
  <www base="~/tmp/www">
    <doc name="doc" zip="~/d1.zip"/>
    <doc name="doc/guide" zip="~/d2.zip"/>
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", wwwPrefix),
      "www doc locations prefix conflict");

  // 4. 无冲突：各挂载与 doc 互不为前缀
  auto noConflict = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <npm/>
  <static base="~/tmp/static">
    <bundle name="x"><dir location="~/x"/></bundle>
  </static>
  <www base="~/tmp/www">
    <doc name="manual" zip="~/m.zip"/>
  </www>
</micdn>`;
  auto config = parse("~/tmp", noConflict);
  assert(config.maven.base.length > 0);
  assert(config.asset.base.length > 0);
  assert(config.www.docs[0].name == "manual");
  assert(config.www.docs[0].endpoint() == "/manual");
}

@("micdn log attributes parse")
unittest {
  auto defaultConsole = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <npm/>
</micdn>`;
  auto c0 = parse("~/tmp", defaultConsole);
  assert(c0.logFile == "console");
  assert(c0.logLevel == "info");

  auto ok = `<?xml version="1.0" encoding="UTF-8"?>
<micdn log-file="/var/log/micdn/micdn.log" log-level="warn">
  <maven/>
  <npm/>
</micdn>`;
  auto config = parse("~/tmp", ok);
  assert(config.logFile == "/var/log/micdn/micdn.log");
  assert(config.logLevel == "warn");

  auto consoleCi = `<?xml version="1.0" encoding="UTF-8"?>
<micdn log-file="Console">
  <maven/>
  <npm/>
</micdn>`;
  assert(parse("~/tmp", consoleCi).logFile == "console");
}

@("parse rejects duplicate root service element after includes")
unittest {
  auto dup = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <maven/>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", dup));
}

@("resolveMicdn checks configured service data roots")
unittest {
  import std.conv : octal;
  import std.zip : ArchiveMember, ZipArchive;

  auto home = buildPath(tempDir, "micdn-resolve-roots");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);

  auto xml = `<?xml version="1.0"?><micdn home="` ~ home ~ `">
  <maven base="` ~ home ~ `/maven"/>
  <npm base="` ~ home ~ `/npm"/>
  <static base="` ~ home ~ `/static">
    <bundle name="x"><dir location="` ~ home ~ `/src"/></bundle>
  </static>
  <www base="` ~ home ~ `/www">
    <doc name="m" zip="` ~ home ~ `/m.zip"/>
  </www>
  <blob base="` ~ home ~ `/blob" maxSize="1M">
    <bucket name="b" key="k"/>
  </blob>
</micdn>`;
  auto config = parse(home, xml);
  mkdirRecurse(home ~ "/src");
  auto zm = new ArchiveMember();
  zm.name = "index.html";
  zm.expandedData(cast(ubyte[]) "x");
  auto z = new ZipArchive();
  z.addMember(zm);
  write(home ~ "/m.zip", z.build());
  assert(resolveMicdn(config));

  config.www.base.setAttributes(octal!555);
  assert(!resolveMicdn(config));
}

@("repo base: empty attribute rejected")
unittest {
  auto dom = parseXml(`<?xml version="1.0"?><micdn><maven base=""/></micdn>`);
  assertThrown(parseMaven("~/maven", dom));
}

@("repo base: dot segments resolved and ~ expanded")
unittest {
  auto dom = parseXml(`<?xml version="1.0"?><micdn><maven base="~/maven/../maven2"/></micdn>`);
  auto config = parseMaven("~/maven", dom);
  assert(config.base == normalizeBasePath("~/maven/../maven2"));
}

@("repo base: ${micdn.home} placeholder expanded")
unittest {
  auto dom = parseXml(`<?xml version="1.0"?><micdn><www base="${micdn.home}/www">
    <doc name="m" zip="/tmp/m.zip"/></www></micdn>`);
  auto config = parseWww("~/home", dom);
  assert(config.base == normalizeBasePath("~/home/www"));
}

@("static bundle rejects unsafe name")
unittest {
  foreach (name; ["", "a/b", `a\b`, ".", ".."]) {
    auto content = `<?xml version="1.0"?><micdn><static base="~/tmp/static">
      <bundle name="` ~ name ~ `"><dir location="~/x"/></bundle></static></micdn>`;
    auto dom = parseXml(content);
    assertThrown(parseAsset("~/tmp", dom), "bundle name `" ~ name ~ "` must be rejected");
  }
}

@("blob bucket rejects unsafe name")
unittest {
  foreach (name; ["", "a/b", `a\b`, ".", ".."]) {
    auto content = `<?xml version="1.0"?><micdn><blob base="/tmp/blob">
      <bucket name="` ~ name ~ `" key="k"/></blob></micdn>`;
    auto dom = parseXml(content);
    assertThrown(parseBlob("~/tmp", dom), "bucket name `" ~ name ~ "` must be rejected");
  }
}
