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

module micdn.model;
/** Micdn 配置模型，负责解析 micdn.xml 并定义静态资源、Maven、Blob 等子配置的数据结构。

    本模块提供 MicdnConfig 根配置类及 AssetConfig、MavenRepoConfig、BlobConfig 等子配置，
    支持从 XML 字符串或文件解析，并可序列化回 micdn.xml 格式。
*/

import std.algorithm;
import std.array;
import std.conv;
import std.datetime.systime;
import std.digest.sha;
import std.file;
import std.string;
import std.uni;

import dxml.dom;

import micdn.xml;

/** 根配置类，聚合静态资源、Maven 仓库、NPM 仓库、Blob 存储、WWW 文档等子配置。

    通过 parse/parseFile 从 XML 加载，通过 staticToXml 序列化回 XML。
*/
class MicdnConfig {
  /// 静态资源配置（endpoint、bundles 等）
  const AssetConfig asset;
  /// Maven 仓库配置（远程镜像、本地路径等）
  const MavenRepoConfig maven;
  /// NPM 仓库配置（endpoint、base、remotes）
  const NpmRepoConfig npm;
  /// Blob 存储配置（profiles、上传限制等）
  const BlobConfig blob;
  /// WWW 文档配置（多 doc，每 doc 独立 endpoint）
  const WwwConfig www;

  this(AssetConfig asset, MavenRepoConfig maven, BlobConfig blob,
      WwwConfig www = null, NpmRepoConfig npm = null) {
    this.asset = asset;
    this.maven = maven;
    this.blob = blob;
    this.www = www;
    this.npm = npm;
  }
  /** 从 XML 字符串解析配置。

      Params:
          home    = 根目录路径，用于展开 ~ 和 ${micdn.home}
          content = micdn.xml 格式的 XML 字符串

      Returns:
          解析得到的 MicdnConfig 实例
  */
  static MicdnConfig parse(string home, string content) {
    auto dom = parseDOM!simpleXML(content).children[0];
    AssetConfig asset;
    MavenRepoConfig maven;
    NpmRepoConfig npm;
    BlobConfig blob;
    WwwConfig www;

    if (dom.children.any!(c => c.name == "maven")) {
      maven = parseMavenConfig("~/.m2/repository", dom);
    } else {
      maven = MavenRepoConfig.defaultConfig();
    }
    if (dom.children.any!(c => c.name == "npmjs")) {
      npm = parseNpmConfig("~/.npm-repo", dom);
    } else {
      npm = NpmRepoConfig.defaultConfig();
    }
    if (dom.children.any!(c => c.name == "static")) {
      asset = parseAssetConfig(home, dom);
    }
    if (dom.children.any!(c => c.name == "blob")) {
      blob = parseBlobConfig(home, dom);
    }
    if (dom.children.any!(c => c.name == "www")) {
      www = parseWwwConfig(home, dom);
    }
    return new MicdnConfig(asset, maven, blob, www, npm);
  }

  /** 从本地 XML 文件解析配置。

      Params:
          home    = 根目录路径，用于展开路径变量
          xmlFile = micdn.xml 文件路径（支持 ~ 展开）

      Returns:
          解析得到的 MicdnConfig 实例

      Throws:
          Exception 当文件不存在时
  */
  static MicdnConfig parseFile(string home, string xmlFile) {
    if (!exists(xmlFile)) {
      throw new Exception(xmlFile ~ " is not exists!");
    }
    return parse(home, readXml(xmlFile));
  }

  /** 将当前配置序列化为 micdn.xml 格式的字符串。

      输出包含 maven、static、blob 三个子节点，bundle 按名称排序。

      Returns:
          完整的 micdn.xml 文本
  */
  string staticToXml() const {
    import std.array;

    auto app = appender!string();
    app.put(`<?xml version="1.0" encoding="UTF-8"?>`);
    app.put("\n");
    app.put("<micdn>");

    // 输出 Maven 配置
    app.put(`  <maven endpoint="` ~ maven.endpoint ~ `" base="` ~ maven.base ~ `">` ~ "\n");
    foreach (remote; maven.remotes) {
      app.put(`    <remote url="` ~ remote ~ `"/>` ~ "\n");
    }
    app.put("  </maven>\n");

    // 输出 NPM 配置
    if (npm) {
      app.put(`  <npmjs endpoint="` ~ npm.endpoint ~ `" base="` ~ npm.base ~ `">` ~ "\n");
      foreach (remote; npm.remotes) {
        app.put(`    <remote url="` ~ remote ~ `"/>` ~ "\n");
      }
      app.put("  </npmjs>\n");
    }

    //output asset config
    app.put(`  <static endpoint="` ~ asset.endpoint ~ `" base="` ~ asset.base ~ `">` ~ "\n");
    auto bundleKeys = asset.bundles.keys.array.sort;
    foreach (key; bundleKeys) {
      auto bundle = asset.bundles[key];
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
        }
      }
      app.put("    </bundle>\n");
    }
    app.put("  </static>\n");

    // 输出 Blob 配置
    if (blob) {
      app.put(`<blob endpoint="` ~ blob.endpoint ~ `" base="` ~ blob.base ~ `">` ~ "\n");
      app.put(`<xi:include href="blob.xml" />`);
      app.put("  </blob>\n");
    }

    // 输出 WWW 配置
    if (www) {
      app.put("  <www base=\"" ~ www.base ~ "\">\n");
      foreach (doc; www.docs) {
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

}

/** 向远程仓库列表末尾追加一项。

    Params:
        remotes = 远程 URL 数组，会被原地修改
        remote  = 要追加的远程仓库地址
*/
private void add(ref string[] remotes, string remote) {
  remotes.length += 1;
  remotes[$ - 1] = remote;
}

/// 去掉 URL 末尾的 /，保证为无斜杠结尾的地址。
private string stripTrailingSlash(string url) {
  return (url.length > 1 && url.endsWith("/")) ? url[0 .. $ - 1] : url;
}

/// 去掉路径开头的 /，zip/npm 的 dir 属性必须为相对路径。
private string stripLeadingSlash(string path) {
  while (path.length > 0 && path[0] == '/')
    path = path[1 .. $];
  return path;
}

/// 解析 Maven 仓库配置（endpoint、本地路径、远程地址）。支持标签 maven 或 repo。
static MavenRepoConfig parseMavenConfig(T)(string defaultBase, ref DOMEntity!T micdnDom) {
  auto mavenEntries = children(micdnDom, "maven");
  auto repoEntries = children(micdnDom, "repo");
  auto dom = !mavenEntries.empty ? mavenEntries.front : repoEntries.front;
  auto attrs = getAttrs(dom);
  import std.path;

  string base = expandTilde(attrs.get("base", defaultBase));
  string endpoint = attrs.get("endpoint", "/maven");
  string[] remoteRepos = [];
  auto remoteEntries = children(dom, "remote");
  foreach (remoteEntry; remoteEntries) {
    remoteRepos.add(stripTrailingSlash(getAttrs(remoteEntry)["url"]));
  }
  if (remoteRepos.length == 0) {
    remoteRepos.add("https://repo1.maven.org/maven2"); // 无配置时使用 Maven 中央仓库
  }
  return new MavenRepoConfig(endpoint, base, remoteRepos);
}

/// 解析 NPM 仓库配置（endpoint、base、remotes）。XML 标签为 npmjs。
static NpmRepoConfig parseNpmConfig(T)(string defaultBase, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "npmjs").front;
  auto attrs = getAttrs(dom);
  import std.path;

  string base = expandTilde(attrs.get("base", defaultBase));
  string endpoint = attrs.get("endpoint", "/npm");
  string[] remoteRepos = [];
  auto remoteEntries = children(dom, "remote");
  foreach (remoteEntry; remoteEntries) {
    remoteRepos.add(stripTrailingSlash(getAttrs(remoteEntry)["url"]));
  }
  if (remoteRepos.length == 0) {
    remoteRepos.add("https://registry.npmmirror.com");
  }
  return new NpmRepoConfig(endpoint, base, remoteRepos);
}

/// 从 DOM 节点解析静态资源配置（endpoint、bundle 及 zip/dir/jar 等 provider）。
static AssetConfig parseAssetConfig(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "static").front;
  auto attrs = getAttrs(dom);
  string endpoint = attrs.get("endpoint", "/static");
  string base = attrs.get("base", "~/.micdn/asset");

  import std.path;

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
static BlobConfig parseBlobConfig(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "blob").front;
  auto attrs = getAttrs(dom);
  import std.path;

  string endpoint = attrs.get("endpoint", "/static");
  string base = expandTilde(attrs.get("base", "~/.micdn/blob"));
  string sizeLimit = attrs.get("maxSize", "50M");

  auto config = new BlobConfig(endpoint, base);
  config.maxSize = parseSize(sizeLimit);
  // 解析数据源属性（如 serverName、databaseName 等）
  auto dataSource = children(dom, "dataSource").front;
  foreach (p; dataSource.children) {
    // FIXME: 应检查 p.children.size
    config.dataSourceProps[p.name] = p.children[0].text;
  }
  return config;
}

/// 从 DOM 节点解析 WWW 配置（多 doc，每 doc 有 location 和至多一个 dir/npm/zip）。
static WwwConfig parseWwwConfig(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "www").front;
  auto attrs = getAttrs(dom);
  import std.path;

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
static ulong parseSize(string size) {
  assert(size.length > 0, "size cannot be empty.");
  string s = size.toLower;
  if (s.endsWith("m")) {
    return s[0 .. $ - 1].to!ulong * 1024 * 1024;
  } else if (s.endsWith("g")) {
    return s[0 .. $ - 1].to!ulong * 1024 * 1024 * 1024;
  } else {
    return s[0 .. $ - 1].to!ulong;
  }
}

/// 规范化 endpoint 路径：空或 "/" 变为空串，末尾 "/" 去掉。
private static string normalizeEndpoint(string base) {
  if (base == null || base == "/") {
    return "";
  } else if (base.endsWith("/")) {
    return base[0 .. $ - 1];
  } else {
    return base;
  }
}

/** 静态资源配置，定义前端资源（JS/CSS 等）的加载来源。

    包含本地存储路径、HTTP 访问前缀、是否允许列目录，以及若干 bundle
    （每个 bundle 可有 zip、dir、jar 等多种 provider）。
*/
class AssetConfig {
  /// 本地资源存储根路径（如 ~/.micdn/asset）
  immutable string base;
  /// HTTP 访问路径前缀（如 /static）
  immutable string endpoint;
  /// bundle 名称 -> AssetBundle 配置的映射
  const AssetBundle[string] bundles;

  this(string endpoint, string base, AssetBundle[string] bundles) {
    this.endpoint = normalizeEndpoint(endpoint);
    this.base = base;
    this.bundles = bundles;
  }
}

/** Maven 仓库的镜像和本地配置。

    支持多个远程仓库 URL，可通过 remoteUrls 获取某个 GAV 在各远程的完整 URL，
    通过 localFile 获取本地缓存路径。
*/
class MavenRepoConfig {
  /// HTTP 访问路径前缀（如 /repo）
  const string endpoint;
  /// 本地 Maven 仓库根路径（如 ~/.m2/repository）
  const string base;
  /// 远程仓库 URL 列表，按优先级排序
  const string[] remotes;

  this(string endpoint, string base, string[] remotes) {
    assert(remotes.all!(r => !r.endsWith("/")), "Maven remote URL must not end with '/'");
    this.endpoint = normalizeEndpoint(endpoint);
    this.remotes = remotes.idup;
    this.base = base;
  }

  static MavenRepoConfig defaultConfig() {
    return new MavenRepoConfig("/repo", "~/.m2/repository", [
      "https://repo1.maven.org/maven2"
    ]);
  }
  /// 将 GAV 转换为 Maven 目录路径，如 org.apache:commons:1.0 -> /org/apache/commons/1.0/commons-1.0.jar
  private string path(string gav) const {
    auto parts = split(gav, ":");
    assert(parts.length == 3);
    parts[0] = replace(parts[0], ".", "/");
    return "/" ~ parts[0] ~ "/" ~ parts[1] ~ "/" ~ parts[2] ~ "/" ~ parts[1] ~ "-"
      ~ parts[2] ~ ".jar";
  }

  /** 返回该 GAV 在各远程仓库的完整下载 URL 列表。

      Params:
          gav = Maven 坐标，格式 groupId:artifactId:version

      Returns:
          各远程 URL 与 path 拼接后的完整 URL 数组
  */
  string[] remoteUrls(string gav) const {
    return remotes.map!(r => r ~ path(gav)).array();
  }

  /** 返回该 GAV 的本地缓存文件路径。

      Params:
          gav = Maven 坐标，格式 groupId:artifactId:version

      Returns:
          本地仓库根路径 + Maven 目录规则拼接后的路径
  */
  string localFile(string gav) const {
    return base ~ path(gav);
  }
}

/** NPM 仓库配置（endpoint、base、remotes）。

    本地路径规则：scope/包名/版本/xxx.tgz，无 scope 时用 "_" 作为目录名。
*/
class NpmRepoConfig {
  /// HTTP 访问路径前缀（如 /npm）
  const string endpoint;
  /// 本地 NPM 仓库根路径（如 ~/.npm-repo）
  const string base;
  /// 远程 registry 列表，默认含 registry.npmmirror.com
  const string[] remotes;

  this(string endpoint, string base, string[] remotes) {
    assert(remotes.all!(r => !r.endsWith("/")), "NPM remote URL must not end with '/'");
    this.endpoint = normalizeEndpoint(endpoint);
    this.remotes = remotes.idup;
    this.base = base;
  }

  static NpmRepoConfig defaultConfig() {
    return new NpmRepoConfig("/npm", "~/.npm-repo", [
      "https://registry.npmmirror.com"
    ]);
  }

  /** 返回包规格对应的本地 tgz 路径。scopePart 无 scope 时传 "_"。
  */
  string localTarball(string scopePart, string namePart, string versionPart) const {
    import std.path;

    string tarballName = (scopePart.length > 0 && scopePart != "_") ? scopePart
      ~ "-" ~ namePart ~ "-" ~ versionPart ~ ".tgz" : namePart ~ "-" ~ versionPart ~ ".tgz";
    return base ~ "/" ~ scopePart ~ "/" ~ namePart ~ "/" ~ versionPart ~ "/" ~ tarballName;
  }
}

/** 静态资源 bundle，对应配置中的一个 <bundle> 节点。

    每个 bundle 有唯一名称和若干 provider（ZipProvider、DirProvider、GavJarProvider），
    用于从 zip 包、本地目录或 Maven jar 加载前端资源。
*/
class AssetBundle {
  /// bundle 名称，不能为空且不能包含 "/"
  const string name;
  /// 资源提供者列表，支持 zip、dir、jar 三种类型
  BundleProvider[] providers = new BundleProvider[0];
  this(string name) {
    assert(name !is null && !name.empty, "name cannot be empty");
    assert(!name.canFind("/"), "name cannot contain /");
    this.name = name;
  }

  /** 向当前 bundle 追加一个资源提供者。

      Params:
          p = ZipProvider、DirProvider 或 GavJarProvider 实例
  */
  void addProvider(BundleProvider p) {
    providers.length += 1;
    providers[providers.length - 1] = p;
  }
}

/** 资源提供者接口，抽象 zip、本地目录、Maven jar 等加载方式。

    子类实现 path() 返回资源定位信息。
*/
interface BundleProvider {
  string path() const;
}

/** 从 ZIP 包内指定目录加载资源。

    对应配置中的 <zip file="..." dir="..." />，将 zip 内 dir 目录挂载到 bundle。
*/
class ZipProvider : BundleProvider {
  /// ZIP 文件路径
  string file;
  /// ZIP 内要挂载的目录路径（相对路径，不以 / 开头）
  string dir;

  this(string file, string dir) {
    assert(dir !is null, "zip dir must not be null");
    assert(dir.length == 0 || !dir.startsWith("/"), "zip dir must not start with '/'");
    this.file = file;
    this.dir = dir;
  }

  override string path() const {
    return file;
  }
}

/** 从本地目录加载资源。

    对应配置中的 <dir location="..." />，将本地目录直接挂载到 bundle。
*/
class DirProvider : BundleProvider {
  /// 本地目录绝对或相对路径（支持 ~ 展开）
  string location;
  this(string location) {
    this.location = location;
  }

  override string path() const {
    return location;
  }
}

/** 从 Maven 仓库的 jar 包加载资源。

    对应配置中的 <jar gav="..." /> 或 <jar gav="..." dir="..." />，
    通过 GAV 从 Maven 仓库下载 jar，并挂载 jar 内指定路径（默认 META-INF/resources）。
*/
class GavJarProvider : BundleProvider {
  /// Maven 坐标，格式 groupId:artifactId:version
  string gav;
  /// jar 内要挂载的子路径（相对路径，不以 / 开头）
  string dir;

  this(string gav, string dir) {
    assert(dir !is null, "jar dir must not be null");
    assert(!dir.startsWith("/"), "jar dir must not start with '/'");
    this.gav = gav;
    this.dir = dir;
  }

  override string path() const {
    return gav;
  }
}

/** 从 NPM 仓库的 tgz 包加载资源。

    对应配置中的 <npm package="@scope/name@version" dir="dist" />，
    格式为 @scope/package@version 或 package@version，dir 默认为 dist。
*/
class NpmProvider : BundleProvider {
  /// NPM 包规格，格式 @scope/package@version 或 package@version
  string packageSpec;
  /// tgz 解压后取包内的子目录，默认 dist（相对路径，不以 / 开头）
  string dir;

  this(string packageSpec, string dir = "dist") {
    assert(dir !is null, "npm dir must not be null");
    assert(!dir.startsWith("/"), "npm dir must not start with '/'");
    this.packageSpec = packageSpec;
    this.dir = dir;
  }

  override string path() const {
    return packageSpec;
  }
}

/** Blob 存储配置，定义文件上传、profile 及数据源。

    包含 endpoint、本地路径、单文件大小限制、profiles 映射、用户密钥，
    以及 PostgreSQL 等数据源的连接属性。
*/
class BlobConfig {
  /// 访问路径前缀
  const string endpoint;
  /// 文件存储根目录
  const string base;
  /// 单文件上传大小限制（字节），默认 50MB
  ulong maxSize = 50 * 1024 * 1024;
  /// 数据源连接属性（如 PostgreSQL）
  string[string] dataSourceProps;

  this(string endpoint, string base) {
    this.endpoint = normalizeEndpoint(endpoint);
    this.base = base;
  }

}

/** WWW 文档配置，包含多个 doc，每个 doc 有独立 endpoint，至多一个 dir/jar/zip 提供者。
*/
class WwwConfig {
  /// 本地构建根路径（如 ~/.micdn/www）
  const string base;
  /// doc 列表，每个 doc 的 location 即其 endpoint
  const WwwDocConfig[] docs;

  this(string base, WwwDocConfig[] docs) {
    this.base = base;
    this.docs = docs;
  }
}

/** 单个 WWW doc 配置，对应一个 endpoint，包含至多一个 dir/jar/zip。
*/
class WwwDocConfig {
  /// HTTP 访问路径前缀（如 /www）
  const string location;
  /// 资源提供者，至多一个（DirProvider、ZipProvider 或 GavJarProvider）
  const BundleProvider provider;

  this(string location, BundleProvider provider) {
    this.location = normalizeEndpoint(location);
    this.provider = provider;
  }
}

/** Blob 元数据记录，对应数据库 blb_blob_metas 表中的一条记录。

    记录上传文件的拥有者、文件名、大小、SHA、存储路径等信息。
*/
class BlobMeta {
  /// 业务上的拥有者标识
  string owner;
  /// 客户端上传的原始文件名
  string name;
  /// 文件大小（字节）
  ulong fileSize;
  /// SHA 摘要
  string sha;
  /// Content-Type
  string mediaType;
  /// 所属 profile 的 id
  int profileId;
  /// 相对于仓库根的存储路径
  string filePath;
  /// 更新时间
  SysTime updatedAt;

  /** 序列化为 JSON 字符串。

      使用简单字符串拼接，未对特殊字符转义，仅用于内部日志或调试。
      FIXME: 存在注入风险，对外输出前应使用标准 JSON 库。
  */
  string toJson() const {
    // FIXME: 简单字符串拼接，未做转义，存在注入风险
    return `{owner:"` ~ owner ~ `",profileId:` ~ profileId.to!string ~ `,name:"` ~ name ~ `",fileSize:`
      ~ fileSize.to!string ~ `,sha:"` ~ sha ~ `",mediaType:"` ~ mediaType
      ~ `",filePath:"` ~ filePath ~ `",updatedAt:"` ~ updatedAt.toISOExtString ~ `"}`;
  }
}

/** Blob 存储 profile，定义路径前缀、可写用户及命名策略。

    每个 profile 对应一个路径前缀（如 /public），有密钥的用户可上传，
    支持 namedBySha（以 SHA 命名文件）和 publicDownload（公开下载）。
*/
class BlobProfile {
  /// profile 主键 id
  const int id;
  /// 路径前缀（如 /public）
  const string base;
  /// 用户名 -> 密钥，有密钥的用户可上传到此 profile
  const string[string] keys;
  /// 是否以 SHA 摘要命名文件
  const bool namedBySha;
  /// 是否允许公开下载
  const bool publicDownload;

  this(int id, string base, string[string] keys, bool namedBySha, bool publicDownload) {
    this.id = id;
    if (base.endsWith("/")) {
      this.base = base[0 .. $ - 1];
    } else {
      this.base = base;
    }
    this.keys = keys;
    this.namedBySha = namedBySha;
    this.publicDownload = publicDownload;
  }

  /** 从 const(BlobProfile) 拷贝构造一个新的 BlobProfile 实例。

      keys 会复制为可变的 string[string]，其余字段按值拷贝。
  */
  static BlobProfile fromConst(const(BlobProfile) p) {
    string[string] keysCopy;
    foreach (k, v; p.keys)
      keysCopy[k] = v;
    return new BlobProfile(p.id, p.base, keysCopy, p.namedBySha, p.publicDownload);
  }

  /** 根据 path、user、key、时间戳生成签名 token。

      Params:
          path      = 请求路径
          user      = 用户名
          key       = 用户密钥
          timestamp = 时间戳

      Returns:
          SHA1 小写十六进制字符串
  */
  string genToken(string path, string user, string key, SysTime timestamp) const {
    string content = path ~ user ~ key ~ timestamp.toISOString;
    return toHexString!(LetterCase.lower)(sha1Of(content)).idup;
  }

  /** 验证 token 是否有效。

      检查时间戳在 15 分钟内，且根据 path、user、key、timestamp 重新计算的
      签名与传入 token 一致。

      Params:
          path      = 请求路径
          user      = 用户名
          key       = 用户密钥
          token     = 客户端传入的 token
          timestamp = 请求中的时间戳

      Returns:
          true 表示验证通过，false 表示过期或签名不匹配
  */
  bool verifyToken(string path, string user, string key, string token, SysTime timestamp) const {
    SysTime today = Clock.currTime();
    import core.time;

    immutable auto duration = abs(today - timestamp);
    if (duration > dur!"minutes"(15)) {
      return false;
    } else {
      string content = path ~ user ~ key ~ timestamp.toISOString;
      return toHexString(sha1Of(content)).toLower == token;
    }
  }
}
