module micdn.asset_test;


@("asset Repository resolve")
unittest {
  auto uri = "/a/b,c.js";
  auto paths = Repository.resolve(uri);
  assert(paths.length == 2);
  assert(paths[1] == "/a/c.js");

  uri = "/a/b,c1/c.min,c2/c.min.js";
  paths = Repository.resolve(uri);
  assert(paths.length == 3);
  assert(paths[1] == "/a/c1/c.min.js");
  assert(paths[2] == "/a/c2/c.min.js");
}

@("asset Repository config parse")
unittest {
  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<assets base="~/tmp/static">
  <repository remote="https://maven.aliyun.com/repository/public"/>
  <contexts>
    <context base="/urp/">
       <dir location="~/.openurp/static"/>
    </context>
    <context base="/my97/">
       <jar gav="org.beangle.bundles:beangle-bundles-my97:4.8"/>
    </context>

    <context base="/bui/">
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.1.7"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.1.4"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.2.0"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.2.1"/>
    </context>
  </contexts>
</assets>`;
  auto config = Config.parse("~/tmp", content);
  assert(config.base == expandTilde("~/tmp/static"));
  assert(config.repo.remotes.length == 2);
}
