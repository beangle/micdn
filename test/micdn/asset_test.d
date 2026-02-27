module micdn.asset_test;

import micdn.asset;
import micdn.model;
import micdn.xml;
import std.path;

@("asset Repository resolve")
unittest {
  auto uri = "/a/b,c.js";
  auto paths = AssetRepo.resolve(uri);
  assert(paths.length == 2);
  assert(paths[1] == "/a/c.js");

  uri = "/a/b,c1/c.min,c2/c.min.js";
  paths = AssetRepo.resolve(uri);
  assert(paths.length == 3);
  assert(paths[1] == "/a/c1/c.min.js");
  assert(paths[2] == "/a/c2/c.min.js");
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
