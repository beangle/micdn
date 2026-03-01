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

import micdn.model;
import micdn.xml;
import std.path;

auto CentralURL = "https://repo1.maven.org/maven2";

@("asset repo remote url")
unittest{
  auto repo = new MavenRepoConfig("/maven", "~/.m2/repository", ["https://repo1.maven.org/maven2"]);
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
  auto config = parseAssetConfig("~/tmp", dom);
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
  auto config = parseMavenConfig("~/.m2/repository", dom);
  assert(config.remotes.length == 2);
  assert(config.remotes[1] == CentralURL);
}

@("blob config parse xml")
unittest {
  auto content = `<?xml version="1.0"?>
<micdn>
  <blob port="9080" context="/micdn" base="/home/chaostone/tmp">
    <dataSource>
      <serverName>localhost</serverName>
      <databaseName>platform</databaseName>
      <user>postgres</user>
      <password>1</password>
      <tableName>public.blb_blob_metas</tableName>
    </dataSource>
  </blob>
</micdn>
`;
  auto dom = parseXml(content);
  auto config = parseBlobConfig("~/tmp", dom);
  import std.stdio;

  assert("databaseName" in config.dataSourceProps);
  assert(10L * 1024 * 1024 * 1024 == parseSize("10g"));
}


@("blob profile token verify")
unittest {
  import std.datetime.systime;
  string[string] keys;
  keys["default"] = "--";
  auto profile = new BlobProfile(0, "", keys, false, false);
  SysTime now = Clock.currTime();
  import core.time;

  now.fracSecs = msecs(0);
  string uri = "/netinstall.sh";
  string token = profile.genToken(uri, "default", "--", now);
  assert(profile.verifyToken(uri, "default", "--", token, now));
}

