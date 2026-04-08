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
  auto repo = new MavenRepoConfig("/maven", "~/maven", ["https://repo1.maven.org/maven2"]);
  auto remoteBui = "https://repo1.maven.org/maven2/org/beangle/bundles/beangle-bundles-bui/0.1.7/beangle-bundles-bui-0.1.7.jar";
  assert(remoteBui == repo.remoteUrls("org.beangle.bundles:beangle-bundles-bui:0.1.7")[0]);
}

@("asset Repository config parse")
unittest {
  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <static base="~/tmp/static" endpoint="/asset">
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
  assert(config.endpoint == "/asset");
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
  <blob endpoint="/blob" base="/tmp/blob" maxSize="10G">
    <bucket name="local" key="test-key-123"/>
  </blob>
</micdn>
`;
  auto dom = parseXml(content);
  auto config = parseBlob("~/tmp", dom);
  assert(config.endpoint == "/blob");
  assert(config.base == "/tmp/blob");
  assert(config.buckets.length == 1);
  assert(config.buckets[0].name == "local");
  assert(config.buckets[0].key == "test-key-123");
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

  assert(isValidEndpoint(""));
  assert(isValidEndpoint("/static"));
  assert(isValidEndpoint("/maven"));
  assert(!isValidEndpoint("/"));
  assert(!isValidEndpoint("/static/"));
  assert(!isValidEndpoint("static"));

  assert(isValidEndpoint(normalizeEndpoint("/maven")));
  assert(isValidEndpoint(normalizeEndpoint("/static/")));
  assert(isValidEndpoint(normalizeEndpoint("asset")));
}

@("endpoint conflict validation")
unittest {
  import std.exception;

  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven endpoint="/maven"/>
  <npm endpoint="/npm"/>
  <static endpoint="/static" base="~/tmp/static">
    <bundle name="x"><dir location="~/x"/></bundle>
  </static>
  <www base="~/tmp/www">
    <doc location="/admin">
      <dir location="~/manual"/>
    </doc>
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", content));

  auto ok = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven endpoint="/maven"/>
  <npm endpoint="/npm"/>
  <static endpoint="/static" base="~/tmp/static">
    <bundle name="x"><dir location="~/x"/></bundle>
  </static>
  <www base="~/tmp/www">
    <doc location="/manual">
      <dir location="~/manual"/>
    </doc>
  </www>
</micdn>`;
  auto config = parse("~/tmp", ok);
  assert(config.www.docs[0].location == "/manual");
}

@("endpoint conflict: prefix and multiple scenarios")
unittest {
  import std.exception;

  // 1. maven /maven 与 static /maven/lib 冲突（前者是后者前缀）
  auto mavenPrefix = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven endpoint="/maven"/>
  <npm endpoint="/npm"/>
  <static endpoint="/maven/lib" base="~/tmp/static">
    <bundle name="x"><dir location="~/x"/></bundle>
  </static>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", mavenPrefix),
      "maven and static endpoint prefix conflict");

  // 2. static /static 与 blob /static/blob 冲突
  auto staticBlob = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven endpoint="/maven"/>
  <npm endpoint="/npm"/>
  <static endpoint="/static" base="~/tmp/static">
    <bundle name="x"><dir location="~/x"/></bundle>
  </static>
  <blob endpoint="/static/blob" base="~/tmp/blob">
    <bucket name="b" key="k"/>
  </blob>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", staticBlob),
      "static and blob endpoint prefix conflict");

  // 3. 两个 www doc: /doc 与 /doc/guide 冲突
  auto wwwPrefix = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven endpoint="/maven"/>
  <npm endpoint="/npm"/>
  <www base="~/tmp/www">
    <doc location="/doc"><dir location="~/d1"/></doc>
    <doc location="/doc/guide"><dir location="~/d2"/></doc>
  </www>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", wwwPrefix),
      "www doc locations prefix conflict");

  // 4. 无冲突：各 endpoint 互不为前缀
  auto noConflict = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven endpoint="/maven"/>
  <npm endpoint="/npm"/>
  <static endpoint="/static" base="~/tmp/static">
    <bundle name="x"><dir location="~/x"/></bundle>
  </static>
  <www base="~/tmp/www">
    <doc location="/manual"><dir location="~/m"/></doc>
  </www>
</micdn>`;
  auto config = parse("~/tmp", noConflict);
  assert(config.maven.endpoint == "/maven");
  assert(config.asset.endpoint == "/static");
  assert(config.www.docs[0].location == "/manual");
}

@("micdn log attributes parse")
unittest {
  auto defaultConsole = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven endpoint="/maven"/>
  <npm endpoint="/npm"/>
</micdn>`;
  auto c0 = parse("~/tmp", defaultConsole);
  assert(c0.logFile == "console");
  assert(c0.logLevel == "info");

  auto ok = `<?xml version="1.0" encoding="UTF-8"?>
<micdn log-file="/var/log/micdn/micdn.log" log-level="warn">
  <maven endpoint="/maven"/>
  <npm endpoint="/npm"/>
</micdn>`;
  auto config = parse("~/tmp", ok);
  assert(config.logFile == "/var/log/micdn/micdn.log");
  assert(config.logLevel == "warn");

  auto consoleCi = `<?xml version="1.0" encoding="UTF-8"?>
<micdn log-file="Console">
  <maven endpoint="/maven"/>
  <npm endpoint="/npm"/>
</micdn>`;
  assert(parse("~/tmp", consoleCi).logFile == "console");
}

@("parse rejects duplicate root service element after includes")
unittest {
  auto dup = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <maven endpoint="/maven"/>
  <maven endpoint="/maven"/>
</micdn>`;
  assertThrown!Exception(parse("~/tmp", dup));
}
