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
import std.file;
import std.string;
import std.uni;

import micdn.config;

/** 根配置类，聚合静态资源、Maven 仓库、NPM 仓库、Blob 存储、WWW 文档等子配置。

    通过 parse/parseFile 从 XML 加载，通过 staticToXml 序列化回 XML。
*/
class MicdnConfig {
  /// 监听地址，格式 host:port，默认 127.0.0.1:8888
  const string listen;
  /// 远程配置 URL，加载时会下载并覆盖本地 micdn.xml
  const string remote;
  /// 根目录，空表示 xml 所在目录，~ 表示用户主目录
  const string home;
  /// 日志输出：`console`（默认，大小写不敏感）为仅控制台；否则为日志文件路径（已展开 ~）。二者互斥。
  const string logFile;
  /// 日志级别：trace、debug、info、warn、error 等
  const string logLevel;
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

  this(AssetConfig asset, MavenRepoConfig maven, BlobConfig blob, WwwConfig www = null,
      NpmRepoConfig npm = null, string listen = "127.0.0.1:8888",
      string remote = null, string home = "", string logFile = "console", string logLevel = "info") {
    this.listen = listen;
    this.remote = remote;
    this.home = home;
    this.logFile = logFile;
    this.logLevel = logLevel;
    this.asset = asset;
    this.maven = maven;
    this.blob = blob;
    this.www = www;
    this.npm = npm;
    validateEndpoints();
  }

  /** 校验所有 endpoint 是否存在冲突（含默认 /admin）。冲突指一个为另一个的前缀。
  */
  private void validateEndpoints() const {
    string[] names, endpoints;
    if (asset !is null) {
      names ~= "static";
      endpoints ~= asset.endpoint;
    }
    names ~= "maven";
    endpoints ~= maven.endpoint;
    names ~= "npm";
    endpoints ~= npm.endpoint;
    if (blob !is null) {
      names ~= "blob";
      endpoints ~= blob.endpoint;
    }
    if (www !is null) {
      foreach (i, doc; www.docs) {
        names ~= "www.doc[" ~ i.to!string ~ "]";
        endpoints ~= doc.location;
      }
    }
    names ~= "admin";
    endpoints ~= "/admin";

    foreach (i; 0 .. endpoints.length) {
      foreach (j; i + 1 .. endpoints.length) {
        auto a = endpoints[i];
        auto b = endpoints[j];
        if (isEndpointPrefix(a, b) || isEndpointPrefix(b, a)) {
          throw new Exception("Endpoint conflict: " ~ names[i] ~ " '" ~ a ~ "' vs "
              ~ names[j] ~ " '" ~ b ~ "'. One must not be a prefix of the other.");
        }
      }
    }
  }

  /// 判断 e1 是否为 e2 的前缀（相同或 e2 以 e1/ 开头）。
  private static bool isEndpointPrefix(string e1, string e2) pure {
    if (e1.length > e2.length)
      return false;
    if (e1.length == e2.length)
      return e1 == e2;
    return e2.startsWith(e1) && e2[e1.length] == '/';
  }

}

/** 规范化 endpoint 路径。

    合法形式：空串、"/"、或以 "/" 开头且不以 "/" 结尾（如 /static）。
    空或 null 或者/ 变为 ""；不以 "/" 开头的添加前导 "/"。
*/
string normalizeEndpoint(string s) {
  if (s is null || s.length == 0)
    return "";
  s = s.strip;
  if (s.length == 0 || s == "/")
    return "";
  if (s[0] != '/')
    s = "/" ~ s;
  while (s.length > 1 && s[$ - 1] == '/')
    s = s[0 .. $ - 1];
  return s;
}

/// 校验 endpoint 是否合法：空串或以 "/" 开头且不以 "/" 结尾。
bool isValidEndpoint(string s) pure {
  if (s.length == 0)
    return true;
  return s[0] == '/' && s.length > 1 && s[$ - 1] != '/';
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
    assert(isValidEndpoint(endpoint),
        "endpoint must be empty, '/', or start with '/' and not end with '/'");
    this.endpoint = endpoint;
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
  /// 本地 Maven 仓库根路径（如 ~/maven
  const string base;
  /// 远程仓库 URL 列表，按优先级排序
  const string[] remotes;

  this(string endpoint, string base, string[] remotes) {
    assert(remotes.all!(r => !r.endsWith("/")), "Maven remote URL must not end with '/'");
    assert(isValidEndpoint(endpoint),
        "endpoint must be empty, '/', or start with '/' and not end with '/'");
    this.endpoint = endpoint;
    this.remotes = remotes.idup;
    this.base = base;
  }

  static MavenRepoConfig defaultConfig() {
    return new MavenRepoConfig("/repo", "~/maven", [
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
  /// 本地 NPM 仓库根路径（如 ~/npm）
  const string base;
  /// 远程 registry 列表，默认含 registry.npmmirror.com
  const string[] remotes;

  this(string endpoint, string base, string[] remotes) {
    assert(remotes.all!(r => !r.endsWith("/")), "NPM remote URL must not end with '/'");
    assert(isValidEndpoint(endpoint),
        "endpoint must be empty, or start with '/' and not end with '/'");
    this.endpoint = endpoint;
    this.remotes = remotes.idup;
    this.base = base;
  }

  static NpmRepoConfig defaultConfig() {
    return new NpmRepoConfig("/npm", "~/npm", ["https://registry.npmmirror.com"]);
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

    每个 bundle 有唯一名称和若干 provider（DirProvider、GavJarProvider、NpmProvider），
    用于从 zip 包、本地目录、Maven jar 或 NPM 包加载前端资源。
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
          p = DirProvider、GavJarProvider 或 NpmProvider 实例
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

  /// 从 GAV 提取 version 部分（最后一组冒号后的内容）。
  string getVersion() const {
    auto idx = gav.lastIndexOf(':');
    return (idx != size_t.max && idx + 1 <= gav.length) ? gav[idx + 1 .. $] : gav;
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

/** 如何从请求解析桶名：`host` 取 Host 首段；`path` 取 endpoint 之后路径的首段。
*/
enum BucketResolveStyle {
  host,
  path,
}

/** Blob 桶：`name` 为磁盘子目录名（不含 `/`），`key` 用于 Bearer 与 S3。

    配置中来自 `<bucket name="…" key="…"/>`；运行时放入 `BlobRepo.buckets`。
    `name` 为空表示未匹配到配置（等价于 `Bucket.init`）。
*/
struct Bucket {
  string name;
  string key;
}

/** Blob 存储配置：endpoint、本地根路径、单文件上限、各 bucket（micdn.xml 内 `<blob>` 下 `<bucket>`）。
*/
class BlobConfig {
  /// 访问路径前缀
  const string endpoint;
  /// 文件存储根目录
  const string base;
  /// 单文件上传大小限制（字节），默认 100MB
  ulong maxSize = 100 * 1024 * 1024;
  /// 桶名解析方式（默认 `host`）
  BucketResolveStyle bucketResolveStyle = BucketResolveStyle.host;
  /// 各桶（物理路径仍为 `base`/`name`/…）
  Bucket[] buckets;

  this(string endpoint, string base) {
    assert(isValidEndpoint(endpoint), "endpoint must be empty, '/', or start with '/' and not end with '/'");
    this.endpoint = endpoint;
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
    assert(isValidEndpoint(location),
        "location must be empty, '/', or start with '/' and not end with '/'");
    this.location = location;
    this.provider = provider;
  }
}

/** Blob 上传结果元数据（值类型；上传响应由 `toJson` 序列化）。
*/
struct BlobMeta {
  /// 客户端上传的原始文件名
  string name;
  /// 文件大小（字节）
  ulong fileSize;
  /// SHA 摘要
  string sha;
  /// Content-Type（由扩展名推断）
  string mediaType;
  /// 桶内逻辑路径（以 `/` 开头，含 SHA 文件名）
  string filePath;
  /// 更新时间（文件 mtime）
  SysTime updatedAt;

  /** 序列化为 JSON 字符串（`std.json`，字段名与值均正确转义）。 */
  string toJson() const {
    import std.json : JSONValue, toJSON;

    JSONValue root = JSONValue.emptyObject;
    root["name"] = JSONValue(name);
    root["fileSize"] = JSONValue(fileSize.to!long);
    root["sha"] = JSONValue(sha);
    root["mediaType"] = JSONValue(mediaType);
    root["filePath"] = JSONValue(filePath);
    root["updatedAt"] = JSONValue(updatedAt.toISOExtString());
    return toJSON(root);
  }
}

