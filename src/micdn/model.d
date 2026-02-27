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

/** 根配置类，聚合静态资源、Maven 仓库、Blob 存储三类子配置。

    通过 parse/parseFile 从 XML 加载，通过 staticToXml 序列化回 XML。
*/
class MicdnConfig {
  /// 静态资源配置（endpoint、bundles 等）
  const AssetConfig asset;
  /// Maven 仓库配置（远程镜像、本地路径等）
  const MavenRepoConfig maven;
  /// Blob 存储配置（profiles、上传限制等）
  const BlobConfig blob;

  this(AssetConfig asset, MavenRepoConfig maven, BlobConfig blob) {
    this.asset = asset;
    this.maven = maven;
    this.blob = blob;
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
    auto asset = parseAssetConfig(home, dom);
    auto maven = parseMavenConfig("~/.m2/repository", dom);
    auto blob = parseBlobConfig(home, dom);
    return new MicdnConfig(asset, maven, blob);
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
    app.put(`  <repo endpoint="` ~ maven.endpoint ~ `" base="` ~ maven.base
        ~ `" publicList="` ~ maven.publicList.to!string ~ `">` ~ "\n");
    foreach (remote; maven.remotes) {
      app.put(`    <remote url="` ~ remote ~ `"/>` ~ "\n");
    }
    app.put("  </repo>\n");

    //output asset config
    app.put(`  <static endpoint="` ~ asset.endpoint ~ `" base="` ~ asset.base
        ~ `" publicList="` ~ asset.publicList.to!string ~ `">` ~ "\n");
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
          app.put(`      <jar gav="` ~ gjp.gav ~ `"/>` ~ "\n");
        }
      }
      app.put("    </bundle>\n");
    }
    app.put("  </static>\n");

    // 输出 Blob 配置
    app.put(`<blob endpoint="` ~ blob.endpoint ~ `" base="` ~ blob.base
        ~ `" publicList="` ~ blob.publicList.to!string ~ `">` ~ "\n");
    app.put(`<xi:include href="blob.xml" />`);
    app.put("  </blob>\n");

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

/// 解析 Maven 仓库配置（endpoint、本地路径、是否公开列表、远程地址）。
static MavenRepoConfig parseMavenConfig(T)(string defaultBase, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "repo").front;
  auto attrs = getAttrs(dom);
  bool publicList = attrs.get("publicList", "false").to!bool;
  import std.path;

  string base = expandTilde(attrs.get("base", defaultBase));
  string endpoint = attrs.get("endpoint", "/repo");
  string[] remoteRepos = [];
  auto remoteEntries = children(dom, "remote");
  foreach (remoteEntry; remoteEntries) {
    remoteRepos.add(getAttrs(remoteEntry)["url"]);
  }
  if (remoteRepos.length == 0) {
    remoteRepos.add("https://repo1.maven.org/maven2"); // 无配置时使用 Maven 中央仓库
  }
  return new MavenRepoConfig(endpoint, base, publicList, remoteRepos);
}

/// 从 DOM 节点解析静态资源配置（endpoint、bundle 及 zip/dir/jar 等 provider）。
static AssetConfig parseAssetConfig(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "static").front;
  auto attrs = getAttrs(dom);
  string endpoint = attrs.get("endpoint", "/static");
  string base = attrs.get("base", "~/.micdn/asset");

  bool publicList = attrs.get("publicList", "false").to!bool;
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
      string location = null;
      if ("location" in attrs) {
        location = attrs["location"];
      }
      bundle.addProvider(new GavJarProvider(gav, location));
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
      string location = attrs["location"];
      bundle.addProvider(new ZipProvider(file, location));
    }
    bundles[bundle.name] = bundle;
  }
  return new AssetConfig(endpoint, base, publicList, bundles.rehash());
}

/// 从 DOM 节点解析 Blob 配置（endpoint、dataSource 等）。
static BlobConfig parseBlobConfig(T)(string home, ref DOMEntity!T micdnDom) {
  auto dom = children(micdnDom, "blob").front;
  auto attrs = getAttrs(dom);
  import std.path;

  string endpoint = attrs.get("endpoint", "/static");
  string base = expandTilde(attrs.get("base", "~/.micdn/blob"));
  string sizeLimit = attrs.get("maxSize", "50M");

  bool publicList = attrs.get("publicList", "false").to!bool;
  auto config = new BlobConfig(endpoint, base, publicList);
  config.maxSize = parseSize(sizeLimit);
  // 解析数据源属性（如 serverName、databaseName 等）
  auto dataSource = children(dom, "dataSource").front;
  foreach (p; dataSource.children) {
    // FIXME: 应检查 p.children.size
    config.dataSourceProps[p.name] = p.children[0].text;
  }
  return config;
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
  /// 是否允许通过 HTTP 列目录
  immutable bool publicList;
  /// HTTP 访问路径前缀（如 /static）
  immutable string endpoint;
  /// bundle 名称 -> AssetBundle 配置的映射
  const AssetBundle[string] bundles;

  this(string endpoint, string base, bool publicList, AssetBundle[string] bundles) {
    this.endpoint = normalizeEndpoint(endpoint);
    this.base = base;
    this.publicList = publicList;
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
  /// 是否允许通过 HTTP 列目录
  const bool publicList;
  /// 远程仓库 URL 列表，按优先级排序
  const string[] remotes;

  this(string endpoint, string base, bool publicList, string[] remotes) {
    this.endpoint = normalizeEndpoint(endpoint);
    this.remotes = remotes.idup;
    this.base = base;
    this.publicList = publicList;
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
  /// ZIP 内要挂载的目录路径
  string dir;

  this(string file, string dir) {
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

    对应配置中的 <jar gav="..." /> 或 <jar gav="..." location="..." />，
    通过 GAV 从 Maven 仓库下载 jar，并挂载 jar 内指定路径（默认 META-INF/resources）。
*/
class GavJarProvider : BundleProvider {
  /// Maven 坐标，格式 groupId:artifactId:version
  string gav;
  /// jar 内要挂载的子路径，空则使用默认路径
  string location;
  this(string gav, string location) {
    this.gav = gav;
    this.location = location;
  }

  override string path() const {
    return gav;
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
  /// 是否允许列目录
  const bool publicList;
  /// 单文件上传大小限制（字节），默认 50MB
  ulong maxSize = 50 * 1024 * 1024;
  /// 数据源连接属性（如 PostgreSQL）
  string[string] dataSourceProps;

  this(string endpoint, string base, bool publicList) {
    this.endpoint = normalizeEndpoint(endpoint);
    this.base = base;
    this.publicList = publicList;
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
