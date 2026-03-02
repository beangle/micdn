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
import std.conv;
import std.file;
import std.path;
import std.string;

import dxml.dom;

import micdn.model;
import micdn.xml;

/** 从 XML 字符串解析 MicdnConfig。
*/
MicdnConfig parse(string home, string content) {
  auto dom = parseDOM!simpleXML(content).children[0];
  AssetConfig asset;
  MavenRepoConfig maven;
  NpmRepoConfig npm;
  BlobConfig blob;
  WwwConfig www;

  if (dom.children.any!(c => c.name == "maven")) {
    maven = parseMaven("~/.m2/repository", dom);
  } else {
    maven = MavenRepoConfig.defaultConfig();
  }
  if (dom.children.any!(c => c.name == "npmjs")) {
    npm = parseNpm("~/.npm-repo", dom);
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
  return new MicdnConfig(asset, maven, blob, www, npm);
}

/** 从本地 XML 文件解析 MicdnConfig。
*/
MicdnConfig parseFile(string home, string xmlFile) {
  if (!exists(xmlFile)) {
    throw new Exception(xmlFile ~ " is not exists!");
  }
  return parse(home, readXml(xmlFile));
}

/** 将 MicdnConfig 序列化为 micdn.xml 格式的字符串。
*/
string toXml(const MicdnConfig config) {
  auto app = appender!string();
  app.put(`<?xml version="1.0" encoding="UTF-8"?>`);
  app.put("\n");
  app.put("<micdn>");

  app.put(`  <maven endpoint="` ~ config.maven.endpoint ~ `" base="` ~ config.maven.base ~ `">` ~ "\n");
  foreach (remote; config.maven.remotes) {
    app.put(`    <remote url="` ~ remote ~ `"/>` ~ "\n");
  }
  app.put("  </maven>\n");

  if (config.npm) {
    app.put(`  <npmjs endpoint="` ~ config.npm.endpoint ~ `" base="` ~ config.npm.base ~ `">` ~ "\n");
    foreach (remote; config.npm.remotes) {
      app.put(`    <remote url="` ~ remote ~ `"/>` ~ "\n");
    }
    app.put("  </npmjs>\n");
  }

  if (config.asset) {
  app.put(`  <static endpoint="` ~ config.asset.endpoint ~ `" base="` ~ config.asset.base ~ `">` ~ "\n");
  auto bundleKeys = config.asset.bundles.keys.array.sort;
  foreach (key; bundleKeys) {
    auto bundle = config.asset.bundles[key];
    app.put(`    <bundle name="` ~ bundle.name ~ `">` ~ "\n");
    foreach (provider; bundle.providers) {
      if (ZipProvider zp = cast(ZipProvider) provider) {
        app.put(`      <zip file="` ~ zp.file ~ `" dir="` ~ zp.dir ~ `"/>` ~ "\n");
      } else if (DirProvider dp = cast(DirProvider) provider) {
        app.put(`      <dir location="` ~ dp.location ~ `"/>` ~ "\n");
      } else if (GavJarProvider gjp = cast(GavJarProvider) provider) {
        if (gjp.dir.length > 0)
          app.put(`      <jar gav="` ~ gjp.gav ~ `" dir="` ~ gjp.dir ~ `"/>` ~ "\n");
        else
          app.put(`      <jar gav="` ~ gjp.gav ~ `"/>` ~ "\n");
      } else if (NpmProvider np = cast(NpmProvider) provider) {
        app.put(`      <npm package="` ~ np.packageSpec ~ `" dir="` ~ np.dir ~ `"/>` ~ "\n");
      }
    }
    app.put("    </bundle>\n");
  }
  app.put("  </static>\n");
  }

  if (config.blob) {
    app.put(`<blob endpoint="` ~ config.blob.endpoint ~ `" base="` ~ config.blob.base ~ `">` ~ "\n");
    app.put(`<xi:include href="blob.xml" />`);
    app.put("  </blob>\n");
  }

  if (config.www) {
    app.put("  <www base=\"" ~ config.www.base ~ "\">\n");
    foreach (doc; config.www.docs) {
      app.put(`    <doc location="` ~ doc.location ~ `">` ~ "\n");
      if (doc.provider) {
        if (auto zp = cast(ZipProvider) doc.provider)
          app.put(`      <zip file="` ~ zp.file ~ `" dir="` ~ zp.dir ~ `"/>` ~ "\n");
        else if (auto dp = cast(DirProvider) doc.provider)
          app.put(`      <dir location="` ~ dp.location ~ `"/>` ~ "\n");
        else if (auto np = cast(NpmProvider) doc.provider)
          app.put(`      <npm package="` ~ np.packageSpec ~ `" dir="` ~ np.dir ~ `"/>` ~ "\n");
      }
      app.put("    </doc>\n");
    }
    app.put("  </www>\n");
  }

  app.put("</micdn>\n");
  return app.data;
}

/// 解析 Maven 仓库配置（endpoint、本地路径、远程地址）。支持标签 maven 或 repo。
MavenRepoConfig parseMaven(T)(string defaultBase, ref DOMEntity!T micdnDom) {
  auto mavenEntries = children(micdnDom, "maven");
  auto repoEntries = children(micdnDom, "repo");
  auto dom = !mavenEntries.empty ? mavenEntries.front : repoEntries.front;
  auto attrs = getAttrs(dom);

  string base = expandTilde(attrs.get("base", defaultBase));
  string endpoint = normalizeEndpoint(attrs.get("endpoint", "/maven"));
  string[] remoteRepos = [];
  auto remoteEntries = children(dom, "remote");
  foreach (remoteEntry; remoteEntries) {
    remoteRepos ~= stripTrailingSlash(getAttrs(remoteEntry)["url"]);
  }
  if (remoteRepos.length == 0) {
    remoteRepos ~= "https://repo1.maven.org/maven2";
  }
  return new MavenRepoConfig(endpoint, base, remoteRepos);
}

/// 解析 NPM 仓库配置（endpoint、base、remotes）。XML 标签为 npmjs。
NpmRepoConfig parseNpm(T)(string defaultBase, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "npmjs").front;
  auto attrs = getAttrs(dom);

  string base = expandTilde(attrs.get("base", defaultBase));
  string endpoint = normalizeEndpoint(attrs.get("endpoint", "/npm"));
  string[] remoteRepos = [];
  auto remoteEntries = children(dom, "remote");
  foreach (remoteEntry; remoteEntries) {
    remoteRepos ~= stripTrailingSlash(getAttrs(remoteEntry)["url"]);
  }
  if (remoteRepos.length == 0) {
    remoteRepos ~= "https://registry.npmmirror.com";
  }
  return new NpmRepoConfig(endpoint, base, remoteRepos);
}

/// 从 DOM 节点解析静态资源配置（endpoint、bundle 及 zip/dir/jar 等 provider）。
AssetConfig parseAsset(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "static").front;
  auto attrs = getAttrs(dom);
  string endpoint = normalizeEndpoint(attrs.get("endpoint", "/static"));
  string base = attrs.get("base", "~/.micdn/asset");

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
    auto zips = children(c, "zip");
    foreach (zip; zips) {
      attrs = getAttrs(zip);
      string file = attrs["file"];
      auto dir = stripLeadingSlash(attrs.get("dir", ""));
      bundle.addProvider(new ZipProvider(file, dir));
    }
    bundles[bundle.name] = bundle;
  }
  return new AssetConfig(endpoint, base, bundles.rehash());
}

/// 从 DOM 节点解析 Blob 配置（endpoint、dataSource 等）。
BlobConfig parseBlob(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "blob").front;
  auto attrs = getAttrs(dom);

  string endpoint = normalizeEndpoint(attrs.get("endpoint", "/static"));
  string base = expandTilde(attrs.get("base", "~/.micdn/blob"));
  string sizeLimit = attrs.get("maxSize", "50M");

  auto config = new BlobConfig(endpoint, base);
  config.maxSize = parseSize(sizeLimit);
  auto dataSourceEntries = children(dom, "dataSource");
  if (!dataSourceEntries.empty) {
    foreach (p; dataSourceEntries.front.children) {
      if (!p.children.empty)
        config.dataSourceProps[p.name] = p.children[0].text;
    }
  }
  return config;
}

/// 从 DOM 节点解析 WWW 配置（多 doc，每 doc 有 location 和至多一个 dir/npm/zip）。
WwwConfig parseWww(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "www").front;
  auto attrs = getAttrs(dom);

  string base = expandTilde(attrs.get("base", "~/.micdn/www"));
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
