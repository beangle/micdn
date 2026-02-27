module micdn.config_test;

@("asset repo remote url")
unittest
{
    immutable(Repo) repo = Repo("https://repo1.maven.org/maven2", "~/.m2/repository");
    auto remoteBui = "https://repo1.maven.org/maven2/org/beangle/bundles/beangle-bundles-bui/0.1.7/beangle-bundles-bui-0.1.7.jar";
    assert(remoteBui == repo.remoteUrls("org.beangle.bundles:beangle-bundles-bui:0.1.7")[0]);
}

@("asset config parse toXml")
unittest
{
    auto content = `<?xml version="1.0" encoding="UTF-8"?>
<assets>
  <repository remote="https://repo1.maven.org/maven2"/>
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
    assert(config.toXml().canFind("https://repo1.maven.org/maven2"));
}

/// 验证 toXml 按第一段路径分组，输出多个 <contexts> 块
@("asset toXml multiple contexts")
unittest
{
    auto content = `<?xml version="1.0" encoding="UTF-8"?>
<asset base="~/.micdn/asset">
  <repository remote="https://repo1.maven.org/maven2"/>
  <contexts>
    <context base="/urp/">
      <dir location="~/.openurp/static"/>
    </context>
    <context base="/my97/">
      <jar gav="org.beangle.bundles:beangle-bundles-my97:4.8"/>
    </context>
    <context base="/bui/">
      <jar gav="org.beangle.bundles:beangle-bundles-bui:0.1.7"/>
    </context>
  </contexts>
</asset>`;

    auto config = Config.parse("~/tmp", content);
    auto xml = config.toXml();

    // 只有一段路径时（/urp、/my97、/bui），都归到根分组 "/"
    assert(count(xml, "</contexts>") == 1, "应只包含 1 个 </contexts> 闭合标签");
    assert(xml.canFind("<contexts base=\"/\">"), "应包含 <contexts base=\"/\"> 分组");

    // 该分组内应有对应的 <context base=\"...\">
    assert(xml.canFind("<context base=\"/urp\">"), "应包含 context /urp");
    assert(xml.canFind("<context base=\"/my97\">"), "应包含 context /my97");
    assert(xml.canFind("<context base=\"/bui\">"), "应包含 context /bui");

    // 同一段路径下多个 context 应归在同一 <contexts> 内
    auto content2 = `<?xml version="1.0" encoding="UTF-8"?>
<asset base="~/.micdn/asset">
  <repository remote="https://repo1.maven.org/maven2"/>
  <contexts base="/lib">
    <context base="/foo"/>
    <context base="/bar"/>
  </contexts>
</asset>`;
    auto config2 = Config.parse("~/tmp", content2);
    auto xml2 = config2.toXml();
    assert(count(xml2, "</contexts>") == 1, "同一段路径 /lib 应只输出一个 <contexts>");
    assert(xml2.canFind("<contexts base=\"/lib\">"), "应包含 <contexts base=\"/lib\">");
    assert(xml2.canFind("<context base=\"/bar\">"), "应包含 <context base=\"/bar\">");
}

@("maven config parse remotes")
unittest
{
    auto content = `<?xml version="1.0" encoding="UTF-8"?>
<maven cacheable="true" >
  <remotes>
    <remote url="https://maven.aliyun.com/nexus/content/groups/public"/>
    <remote alias="central"/>
  </remotes>
</maven>`;

    auto config = Config.parse("~/.m2/repository", content);
    assert(config.remoteRepos.length == 2);
    assert(config.remoteRepos[1] == Config.CentralURL);
}

@("blob config parse xml")
unittest {
  auto content = `<?xml version="1.0"?>
<blob port="9080" context="/micdn" base="/home/chaostone/tmp">
  <users>
    <user name="default" key="--"/>
  </users>
  <profiles>
    <profile id="0" base="/group/test" users="default"/>
  </profiles>
  <dataSource>
    <serverName>localhost</serverName>
    <databaseName>platform</databaseName>
    <user>postgres</user>
    <password>1</password>
    <tableName>public.blb_blob_metas</tableName>
  </dataSource>
</blob>`;
  auto config = Config.parse(content);
  import std.stdio;

  assert(config.profiles.length == 1);
  assert("/group/test" in config.profiles);
  assert("databaseName" in config.dataSourceProps);
  assert(10L * 1024 * 1024 * 1024 == config.parseSize("10g"));
}


@("blob profile token verify")
unittest {
  string[string] keys;
  keys["default"] = "--";
  auto profile = new Profile(0, "", keys, false, false);
  SysTime now = Clock.currTime();
  import core.time;

  now.fracSecs = msecs(0);
  string uri = "/netinstall.sh";
  string token = profile.genToken(uri, "default", "--", now);
  //import std.stdio;
  //writeln( "token="~token~"&t="~now.toISOString);
  assert(profile.verifyToken(uri, "default", "--", token, now));
}

