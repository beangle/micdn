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

import std.exception;
import std.path;

import micdn.config;
import micdn.model;
import micdn.xml;

auto CentralURL = "https://repo1.maven.org/maven2";

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

@("www doc parses npm dir zip attributes")
unittest {
  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="manual" npm="@xurp/manual@0.0.2" />
    <doc name="local" dir="~/docs/local" />
    <doc name="zipdoc" zip="~/docs/pkg.zip" inner="dist" />
  </www>
</micdn>`;
  auto config = parse("~/tmp", xml);
  assert(config.www.docs.length == 3);
  assert(cast(NpmProvider) config.www.docs[0].provider !is null);
  assert(cast(DirProvider) config.www.docs[1].provider !is null);
  assert(cast(ZipProvider) config.www.docs[2].provider !is null);
  assert((cast(NpmProvider) config.www.docs[0].provider).dir == "dist");
  assert((cast(ZipProvider) config.www.docs[2].provider).dir == "dist");
}

@("www doc rejects multiple source attributes")
unittest {
  import std.exception;

  auto xml = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/><npm/>
  <www base="~/tmp/www">
    <doc name="manual" npm="@a/b@1" dir="~/m"/>
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
    <doc name="manual/../admin" dir="~/m"/>
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
    <doc name="/" dir="~/m"/>
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", emptyLoc));

  auto missingLoc = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven/>
  <npm/>
  <www base="~/tmp/www">
    <doc dir="~/m"/>
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
  auto doc = new WwwDocConfig("a/b", null);
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
    <doc name="admin" dir="~/manual"/>
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
    <doc name="manual" dir="~/manual"/>
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
    <doc name="maven" dir="~/m"/>
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
    <doc name="blob" dir="~/m"/>
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
    <doc name="doc" dir="~/d1"/>
    <doc name="doc/guide" dir="~/d2"/>
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
    <doc name="manual" dir="~/m"/>
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
