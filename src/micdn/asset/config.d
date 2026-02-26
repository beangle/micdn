module micdn.asset.config;
/// 静态资源仓库与上下文的配置解析、归一化与 XML 生成。

import std.file;
import std.algorithm;
import std.string;
import std.array;
import std.conv;
import dxml.dom;
import micdn.xml.reader;
import std.array : appender;

struct Repo {
  immutable string[] remotes;
  immutable string local;

  private string path(string gav) immutable {
    auto parts = split(gav, ":");
    assert(parts.length == 3);
    parts[0] = replace(parts[0], ".", "/");
    return "/" ~ parts[0] ~ "/" ~ parts[1] ~ "/" ~ parts[2] ~ "/" ~ parts[1] ~ "-"
      ~ parts[2] ~ ".jar";
  }

  this(string[] remotes, string local) {
    this.remotes = remotes.idup;
    this.local = local;
  }

  this(string remote, string local) {
    this.remotes = [remote];
    this.local = local;
  }

  string[] remoteUrls(string gav) immutable {
    return remotes.map!(r => r ~ path(gav)).array();
  }

  string localFile(string gav) immutable {
    return local ~ path(gav);
  }
}

class Config {
  immutable Repo repo;
  /*本地资源存储路径，默认是~/.micdn/asset*/
  immutable string base;
  /**enable dir list*/
  immutable bool publicList;

  const Context[string] contexts;

  this(string base, Repo repo, bool publicList, Context[string] contexts) {
    this.base = base;
    this.repo = repo;
    this.publicList = publicList;
    this.contexts = contexts;
  }

  public static Config parse(string home, string content) {
    auto dom = parseDOM!simpleXML(content).children[0];
    auto attrs = getAttrs(dom);
    string base = attrs.get("base", "~/.micdn/asset");
    bool publicList = attrs.get("publicList", "false").to!bool;
    auto repoEntry = children(dom, "repository");
    auto defaultRemote = "https://repo1.maven.org/maven2";
    string[] remotes = [defaultRemote];
    auto local = "~/.m2/repository";
    if (!repoEntry.empty) {
      attrs = getAttrs(repoEntry.front);
      if ("remote" in attrs) {
        auto remote = attrs["remote"];
        if (remote != defaultRemote) {
          remotes = [remote, defaultRemote];
        }
      }
      if ("local" in attrs) {
        local = attrs["local"];
      }
    }
    import std.path;

    base = expandTilde(base);
    Context[string] ctxMap;
    auto contextsEntries = children(dom, "contexts");

    foreach (contextsNode; contextsEntries) {
      auto ctxBase = normalize(getAttrs(contextsNode).get("base", ""));
      auto contextEntries = children(contextsNode, "context");
      foreach (c; contextEntries) {
        auto context = new Context(ctxBase ~ normalize(getAttrs(c).get("base", "")));
        auto jars = children(c, "jar");
        foreach (jar; jars) {
          attrs = getAttrs(jar);
          string gav = attrs["gav"];
          string location = null;
          if ("location" in attrs) {
            location = attrs["location"];
          }
          context.addProvider(new GavJarProvider(gav, location));
        }
        auto dirs = children(c, "dir");
        foreach (dir; dirs) {
          attrs = getAttrs(dir);
          string location = expandTilde(attrs["location"].replace("${micdn.home}", home));
          context.addProvider(new DirProvider(location));
        }
        auto zips = children(c, "zip");
        foreach (zip; zips) {
          attrs = getAttrs(zip);
          string file = attrs["file"];
          string location = attrs["location"];
          context.addProvider(new ZipProvider(file, location));
        }
        ctxMap[context.base] = context;
      }
    }
    return new Config(base, Repo(remotes, expandTilde(local)), publicList, ctxMap.rehash());
  }

  static string normalize(string base) {
    if (base == null || base == "/") {
      return "";
    } else if (base.endsWith("/")) {
      return base[0 .. $ - 1];
    } else {
      return base;
    }
  }

  /// 取 base 的第一段路径作为分组键。
  /// - 若有两段或以上（例如 "/lib/foo"），返回第一段 "/lib"
  /// - 否则（例如 ""、"/"、"/lib"），返回根路径 "/"
  private static string firstSegment(string base) {
    size_t slashCount = 0;
    foreach (i, ch; base) {
      if (ch == '/') {
        ++slashCount;
        // 第二个斜杠，说明至少有两段，返回第一段
        if (slashCount == 2) {
          return base[0 .. i];
        }
      }
    }
    return "/"; // 只有 0 或 1 个斜杠，归到根分组
  }

  string toXml() const {
    import std.array;

    auto app = appender!string();
    app.put(`<?xml version="1.0" encoding="UTF-8"?>`);
    app.put("\n");
    app.put("<asset base=\"" ~ base ~ "\">\n");
    app.put("  <repository remote=\"" ~ repo.remotes.join(
        ",") ~ "\" local=\"" ~ repo.local ~ "\" />\n");
    // 在 toXml 内按第一段路径分组，输出多个 <contexts>
    string[][string] groupKeys; // segment -> [context.base, ...]
    foreach (c; contexts.values) {
      auto seg = firstSegment(c.base);
      groupKeys[seg] ~= c.base;
    }
    auto segments = array(groupKeys.keys);
    segments.sort;
    foreach (seg; segments) {
      auto bases = groupKeys[seg];
      bases.sort;
      if (seg.length > 0) {
        app.put("  <contexts base=\"" ~ seg ~ "\">\n");
      } else {
        app.put("  <contexts>\n");
      }
      foreach (b; bases) {
        app.put(contexts[b].toXml("    ", seg));
        app.put("\n");
      }
      app.put("  </contexts>\n");
    }
    app.put("</asset>\n");
    return app.data;
  }

}

class Context {
  //不能为空,也不能是/结尾
  const string base;
  Provider[] providers = new Provider[0];
  this(string base) {
    assert(!base.endsWith("/"), "base cannot be ended with /");
    this.base = base;
  }

  void addProvider(Provider p) {
    providers.length += 1;
    providers[providers.length - 1] = p;
  }

  string toXml(string indent, string groupBase) const {
    auto app = appender!string();
    app.put(indent ~ "<context base=\"" ~ innerBase(groupBase) ~ "\">\n");
    foreach (p; providers) {
      app.put(p.toXml(indent ~ "  "));
      app.put("\n");
    }
    app.put(indent ~ "</context>");
    return app.data;
  }

  private string innerBase(string groupBase) const {
    if (groupBase == "/") {
      return base;
    } else {
      return base[groupBase.length .. $];
    }
  }
}

interface Provider {
  string path() const;
  string toXml(string indent) const;
}

class ZipProvider : Provider {
  string file;
  string location;

  this(string file, string location) {
    this.file = file;
    this.location = location;
  }

  override string path() const {
    return file;
  }

  string toXml(string indent) const {
    return indent ~ `<zip file="` ~ file ~ `" location="` ~ location ~ `"/>`;
  }
}

class DirProvider : Provider {
  string location;
  this(string location) {
    this.location = location;
  }

  override string path() const {
    return location;
  }

  string toXml(string indent) const {
    return indent ~ `<dir location="` ~ location ~ `"/>`;
  }
}

class GavJarProvider : Provider {
  string gav;
  string location;
  this(string gav, string location) {
    this.gav = gav;
    this.location = location;
  }

  override string path() const {
    return gav;
  }

  string toXml(string indent) const {
    string loc = "";
    if (null != location) {
      loc = " location=\"" ~ location ~ "\" ";
    }
    return indent ~ `<jar gav="` ~ gav ~ loc ~ `"/>`;
  }
}

@("asset repo remote url")
unittest {
  immutable(Repo) repo = Repo("https://repo1.maven.org/maven2", "~/.m2/repository");
  auto remoteBui = "https://repo1.maven.org/maven2/org/beangle/bundles/beangle-bundles-bui/0.1.7/beangle-bundles-bui-0.1.7.jar";
  assert(remoteBui == repo.remoteUrls("org.beangle.bundles:beangle-bundles-bui:0.1.7")[0]);
}

@("asset config parse toXml")
unittest {
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
unittest {
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
