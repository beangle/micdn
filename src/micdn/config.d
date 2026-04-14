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

module micdn.config;
/// micdn.xml 解析与序列化逻辑。

import std.algorithm;
import std.array;
import std.conv : text, to;
import std.path;
import std.process;
import std.string;
import std.uni : icmp;

import dxml.dom;

import micdn.logging;
import micdn.model;
import micdn.xml;

/** 解析 home 属性：空=默认目录，~=用户主目录，否则 expandTilde。
*/
private string resolveHome(string homeAttr, string defaultDir) {
  if (homeAttr.length == 0)
    return defaultDir;
  if (homeAttr == "~")
    return expandTilde("~");
  return expandTilde(homeAttr);
}

/** 展开 include 后校验：maven、npm、blob、static、www 各至多出现一次。
*/
private void validateMicdnServiceElementsUnique(T)(ref DOMEntity!T dom) {
  foreach (name; ["maven", "npm", "blob", "static", "www"]) {
    size_t n = 0;
    foreach (c; dom.children) {
      if (c.name == name)
        n++;
    }
    if (n > 1)
      throw new Exception(i`Duplicate <$(name)> element in micdn.xml (after includes)`.text);
  }
}

/** 从 XML 字符串解析 MicdnConfig。defaultHome 为 xml 所在目录，用于 home 属性为空时。
*/
MicdnConfig parse(string defaultHome, string content) {
  auto dom = parseDOM!simpleXML(content).children[0];
  validateMicdnServiceElementsUnique(dom);
  auto rootAttrs = getAttrs(dom);
  string listen = rootAttrs.get("listen", "127.0.0.1:8888");
  string remote = rootAttrs.get("remote", "");
  auto home = resolveHome(rootAttrs.get("home", ""), defaultHome);

  string logFile = rootAttrs.get("log-file", "console").strip();
  if (logFile.length == 0)
    logFile = "console";
  if (icmp(logFile, "console") == 0)
    logFile = "console";
  else
    logFile = expandTilde(logFile);
  string logLevel = rootAttrs.get("log-level", "info").strip();
  if (logLevel.length == 0)
    logLevel = "info";
  parseLogLevel(logLevel);

  AssetConfig asset;
  MavenRepoConfig maven;
  NpmRepoConfig npm;
  BlobConfig blob;
  WwwConfig www;

  if (dom.children.any!(c => c.name == "maven")) {
    maven = parseMaven(home, dom);
  } else {
    maven = MavenRepoConfig.defaultConfig();
  }
  if (dom.children.any!(c => c.name == "npm")) {
    npm = parseNpm(home, dom);
  } else {
    npm = NpmRepoConfig.defaultConfig();
  }
  if (dom.children.any!(c => c.name == "static")) {
    asset = parseAsset(home, dom);
  }
  if (dom.children.any!(c => c.name == "blob")) {
    blob = parseBlob(home, dom);
  }
  if (dom.children.any!(c => c.name == "www")) {
    www = parseWww(home, dom);
  }
  return new MicdnConfig(asset, maven, blob, www, npm, listen, remote, home, logFile, logLevel);
}

/** 从本地 XML 文件解析 MicdnConfig。
*/
MicdnConfig parseFile(string xmlFile) {
  string content = readXml(xmlFile);
  string abs = absolutePath(expandTilde(xmlFile));
  return parse(dirName(abs), content);
}

/** 将 MicdnConfig 序列化为 micdn.xml 格式的字符串。
*/
string toXml(const MicdnConfig config) {
  auto app = appender!string();
  app.put(i`<?xml version="1.0" encoding="UTF-8"?>
<micdn xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xmlns:xi="http://www.w3.org/2001/XInclude"
  xsi:noNamespaceSchemaLocation="http://beangle.github.io/schema/micdn-1.0.0.xsd"
  listen="$(
      config.listen)"`.text);
  if (config.remote !is null && config.remote.length > 0)
    app.put(i` remote="$(config.remote)"`.text);
  if (config.home.length > 0)
    app.put(i` home="$(config.home)"`.text);
  if (config.logFile != "console")
    app.put(i` log-file="$(config.logFile)"`.text);
  if (config.logLevel != "info")
    app.put(i` log-level="$(config.logLevel)"`.text);
  app.put(">");

  app.put(i`  <maven base="$(config.maven.base)">`.text);
  app.put("\n");
  foreach (remote; config.maven.remotes) {
    app.put(i`    <remote url="$(remote)"/>`.text);
    app.put("\n");
  }
  app.put("  </maven>\n");

  if (config.npm) {
    app.put(i`  <npm base="$(config.npm.base)">`.text);
    app.put("\n");
    foreach (remote; config.npm.remotes) {
      app.put(i`    <remote url="$(remote)"/>`.text);
      app.put("\n");
    }
    app.put("  </npm>\n");
  }

  if (config.blob) {
    const blobBase = escapeXmlAttr(config.blob.base);
    const blobMs = formatSizeForXml(config.blob.maxSize);
    app.put(i`  <blob base="$(blobBase)" maxSize="$(blobMs)">`.text);
    app.put("\n");
    foreach (b; config.blob.buckets) {
      if (!b.publicImages)
        app.put(i`    <bucket name="$(escapeXmlAttr(b.name))" key="$(escapeXmlAttr(b.key))" publicImages="false"/>`.text);
      else
        app.put(i`    <bucket name="$(escapeXmlAttr(b.name))" key="$(escapeXmlAttr(b.key))"/>`.text);
      app.put("\n");
    }
    app.put("  </blob>\n");
  }

  if (config.asset) {
    app.put(i`  <static base="$(config.asset.base)">`.text);
    app.put("\n");
    auto bundleKeys = config.asset.bundles.keys.array.sort;
    foreach (key; bundleKeys) {
      auto bundle = config.asset.bundles[key];
      app.put(i`    <bundle name="$(bundle.name)">`.text);
      app.put("\n");
      foreach (provider; bundle.providers) {
        if (DirProvider dp = cast(DirProvider) provider) {
          app.put(i`      <dir location="$(dp.location)"/>`.text);
          app.put("\n");
        } else if (GavJarProvider gjp = cast(GavJarProvider) provider) {
          if (gjp.dir.length > 0)
            app.put(i`      <jar gav="$(gjp.gav)" dir="$(gjp.dir)"/>`.text);
          else
            app.put(i`      <jar gav="$(gjp.gav)"/>`.text);
          app.put("\n");
        } else if (NpmProvider np = cast(NpmProvider) provider) {
          app.put(i`      <npm package="$(np.packageSpec)" dir="$(np.dir)"/>`.text);
          app.put("\n");
        }
      }
      app.put("    </bundle>\n");
    }

    app.put("  </static>\n");
  }

  if (config.www) {
    app.put(i`  <www base="$(config.www.base)">`.text);
    app.put("\n");
    foreach (doc; config.www.docs) {
      app.put(i`    <doc location="$(doc.location)">`.text);
      app.put("\n");
      if (doc.provider) {
        if (auto zp = cast(ZipProvider) doc.provider) {
          app.put(i`      <zip file="$(zp.file)" dir="$(zp.dir)"/>`.text);
          app.put("\n");
        } else if (auto dp = cast(DirProvider) doc.provider) {
          app.put(i`      <dir location="$(dp.location)"/>`.text);
          app.put("\n");
        } else if (auto np = cast(NpmProvider) doc.provider) {
          app.put(i`      <npm package="$(np.packageSpec)" dir="$(np.dir)"/>`.text);
          app.put("\n");
        }
      }
      app.put("    </doc>\n");
    }
    app.put("  </www>\n");
  }

  app.put("</micdn>\n");
  return app.data;
}

/// 解析 Maven 仓库配置（本地路径、远程地址）。支持标签 maven 或 repo。
MavenRepoConfig parseMaven(T)(string home, ref DOMEntity!T micdnDom) {
  auto mavenEntries = children(micdnDom, "maven");
  auto repoEntries = children(micdnDom, "repo");
  auto dom = !mavenEntries.empty ? mavenEntries.front : repoEntries.front;
  auto attrs = getAttrs(dom);

  string base = expandTilde(attrs.get("base", home ~ "/maven")).replace("${micdn.home}", home);
  string[] remoteRepos = [];
  auto remoteEntries = children(dom, "remote");
  foreach (remoteEntry; remoteEntries) {
    remoteRepos ~= stripTrailingSlash(getAttrs(remoteEntry)["url"]);
  }
  if (remoteRepos.length == 0) {
    remoteRepos ~= "https://repo1.maven.org/maven2";
  }
  return new MavenRepoConfig(base, remoteRepos);
}

/// 解析 NPM 仓库配置（base、remotes）。根级 XML 标签为 npm。
NpmRepoConfig parseNpm(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "npm").front;
  auto attrs = getAttrs(dom);

  string base = expandTilde(attrs.get("base", home ~ "/npm")).replace("${micdn.home}", home);
  string[] remoteRepos = [];
  auto remoteEntries = children(dom, "remote");
  foreach (remoteEntry; remoteEntries) {
    remoteRepos ~= stripTrailingSlash(getAttrs(remoteEntry)["url"]);
  }
  if (remoteRepos.length == 0) {
    remoteRepos ~= "https://registry.npmmirror.com";
  }
  return new NpmRepoConfig(base, remoteRepos);
}

/// 从 DOM 节点解析静态资源配置（bundle 及 zip/dir/jar 等 provider）。
AssetConfig parseAsset(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "static").front;
  auto attrs = getAttrs(dom);
  string base = attrs.get("base", home ~ "/asset").replace("${micdn.home}", home);

  base = expandTilde(base);
  AssetBundle[string] bundles;
  auto bundleEntries = children(dom, "bundle");

  foreach (c; bundleEntries) {
    auto bundle = new AssetBundle(getAttrs(c).get("name", ""));
    auto jars = children(c, "jar");
    foreach (jar; jars) {
      attrs = getAttrs(jar);
      string gav = attrs["gav"];
      auto rawDir = attrs.get("dir", "");
      string dir = rawDir.length == 0 ? (gav.startsWith("org.webjars")
          ? "META-INF/resources/webjars" : "META-INF/resources") : stripLeadingSlash(rawDir);
      bundle.addProvider(new GavJarProvider(gav, dir));
    }
    auto npms = children(c, "npm");
    foreach (npm; npms) {
      attrs = getAttrs(npm);
      string packageSpec = attrs["package"];
      auto dir = stripLeadingSlash(attrs.get("dir", "dist"));
      bundle.addProvider(new NpmProvider(packageSpec, dir));
    }
    auto dirs = children(c, "dir");
    foreach (dir; dirs) {
      attrs = getAttrs(dir);
      string location = expandTilde(attrs["location"].replace("${micdn.home}", home));
      bundle.addProvider(new DirProvider(location));
    }
    bool hasDir;
    bool hasJarOrNpm;
    foreach (p; bundle.providers) {
      if (cast(DirProvider) p)
        hasDir = true;
      if (cast(GavJarProvider) p || cast(NpmProvider) p)
        hasJarOrNpm = true;
    }
    if (hasDir && hasJarOrNpm)
      throw new Exception(`static <bundle name="` ~ bundle.name
          ~ `"> cannot mix <dir> with <jar> or <npm>`);
    // AssetBundle 不支持 zip，仅 www doc 支持
    bundles[bundle.name] = bundle;
  }
  return new AssetConfig(base, bundles.rehash());
}

/// XML 布尔属性：`false` / `0` / `no` 为假，`true` / `1` / `yes` 为真（大小写不敏感）。
/// 空串或不能识别为上述字面量的其它非空串，返回 `defaultWhenEmpty`（属性缺省时常与桶的默认一致，如 `publicImages` 用 `true`）。
private bool parseBoolXmlAttr(string s, bool defaultWhenEmpty = false) {
  import std.uni : icmp;

  s = s.strip();
  if (s.length == 0)
    return defaultWhenEmpty;
  if (icmp(s, "false") == 0 || icmp(s, "0") == 0 || icmp(s, "no") == 0)
    return false;
  if (icmp(s, "true") == 0 || icmp(s, "1") == 0 || icmp(s, "yes") == 0)
    return true;
  return defaultWhenEmpty;
}

/// 解析单个 `<bucket>` 节点为 `Bucket`。
Bucket parseBlobBucket(T)(ref DOMEntity!T dom) {
  auto attrs = getAttrs(dom);
  string name = attrs.get("name", "").strip();
  if (name.length == 0)
    throw new Exception("blob <bucket> requires a non-empty name attribute");
  if (name.indexOf('/') >= 0 || name.indexOf('\\') >= 0)
    throw new Exception("blob <bucket> name must not contain '/' or '\\'");

  string key = attrs.get("key", "").strip();
  if (key.length == 0)
    throw new Exception("blob <bucket> requires a non-empty key attribute");

  bool publicImages = parseBoolXmlAttr(attrs.get("publicImages", ""), true);
  return Bucket(name, key, publicImages);
}

/// 从 DOM 节点解析 Blob 配置（`<bucket>` 的 name/key）。
BlobConfig parseBlob(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "blob").front;
  auto attrs = getAttrs(dom);

  string base = attrs.get("base", home ~ "/blob").replace("${micdn.home}", home);
  base = expandTilde(base);
  string sizeLimit = attrs.get("maxSize", "100M");

  auto config = new BlobConfig(base);
  config.maxSize = parseSize(sizeLimit);

  Bucket[] buckets;
  foreach (dn; children(dom, "bucket")) {
    buckets ~= parseBlobBucket(dn);
  }
  config.buckets = buckets;

  if (config.buckets.length == 0)
    throw new Exception("blob: no <bucket> configured under <blob>");

  return config;
}

/// 从 DOM 节点解析 WWW 配置（多 doc，每 doc 有 location 和至多一个 dir/npm/zip）。
WwwConfig parseWww(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "www").front;
  auto attrs = getAttrs(dom);

  string base = expandTilde(attrs.get("base", home ~ "/www")).replace("${micdn.home}", home);
  WwwDocConfig[] docs;
  foreach (c; children(dom, "doc")) {
    auto docAttrs = getAttrs(c);
    string location = normalizeEndpoint(docAttrs.get("location", ""));
    if (location.empty)
      continue;
    BundleProvider provider = null;
    auto npms = children(c, "npm");
    if (!npms.empty) {
      attrs = getAttrs(npms.front);
      string packageSpec = attrs["package"];
      auto dir = stripLeadingSlash(attrs.get("dir", "dist"));
      provider = new NpmProvider(packageSpec, dir);
    }
    auto dirs = children(c, "dir");
    if (!dirs.empty && provider is null) {
      attrs = getAttrs(dirs.front);
      string loc = expandTilde(attrs["location"].replace("${micdn.home}", home));
      provider = new DirProvider(loc);
    }
    auto zips = children(c, "zip");
    if (!zips.empty && provider is null) {
      attrs = getAttrs(zips.front);
      string file = expandTilde(attrs["file"].replace("${micdn.home}", home));
      auto dir = stripLeadingSlash(attrs.get("dir", ""));
      provider = new ZipProvider(file, dir);
    }
    docs ~= new WwwDocConfig(location, provider);
  }
  return new WwwConfig(base, docs);
}

/// 将字节数格式化为与 `parseSize` 可逆的 `maxSize` 属性（优先 `…M` / `…G`）。
private string formatSizeForXml(ulong bytes) {
  import std.format : format;

  enum ulong g = 1024UL * 1024 * 1024;
  enum ulong m = 1024UL * 1024;
  if (bytes != 0 && bytes % g == 0)
    return format("%sG", bytes / g);
  if (bytes != 0 && bytes % m == 0)
    return format("%sM", bytes / m);
  return bytes.to!string;
}

private string escapeXmlAttr(string s) {
  import std.array : appender;

  auto app = appender!string();
  foreach (c; s) {
    switch (c) {
    case '&':
      app.put("&amp;");
      break;
    case '"':
      app.put("&quot;");
      break;
    case '<':
      app.put("&lt;");
      break;
    default:
      app.put(c);
      break;
    }
  }
  return app.data;
}

/// 解析大小字符串，支持 M/G 后缀（如 "50M"、"1G"）。
ulong parseSize(string size) {
  assert(size.length > 0, "size cannot be empty.");
  string s = size.toLower;
  if (s.endsWith("m")) {
    return s[0 .. $ - 1].to!ulong * 1024 * 1024;
  } else if (s.endsWith("g")) {
    return s[0 .. $ - 1].to!ulong * 1024 * 1024 * 1024;
  } else {
    return s.to!ulong;
  }
}

private string stripTrailingSlash(string url) {
  return (url.length > 1 && url.endsWith("/")) ? url[0 .. $ - 1] : url;
}

private string stripLeadingSlash(string path) {
  while (path.length > 0 && path[0] == '/')
    path = path[1 .. $];
  return path;
}
