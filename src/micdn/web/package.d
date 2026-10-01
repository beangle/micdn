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

module micdn.web;
/// HTTP 路径解析、仓库 URI 防护与配置路径解析。

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.regex;
import std.string;
import std.typecons;

import dxml.dom;

import vibe.core.args;
import vibe.http.server;

import micdn.web.file;
import micdn.xml;

/** HTTP 入口解析出的仓库资源 URI。

    - `segs`：已消解的路径段（不含 `.`/`..`、中间空段已合并），**不含尾斜杠空段**；空数组表示仓库根；
    - `invalid`：点段越界（试图逃出根）等解析失败（见 `ok`）；
    - `slashEnded`：原始 uri 是否以 `/` 结尾（如 `/maven/` → `segs=[]`、`slashEnded=true`）。

    下游（仓库 `get`、`repositoryUri`、`repositoryPath`）直接读取字段，无需再截取末尾空段。
*/
struct ResourceUri {
  /// 已消解路径段；空数组表示仓库根
  const(string)[] segs;
  /// 原始 uri 是否以 `/` 结尾
  bool slashEnded;
  /// 解析失败（点段越界试图逃出根）
  private bool invalid;

  /// 解析是否成功。**不能用 `segs is null` 判定**：D 的空数组字面量 `[]` 本身就是 null，
  /// 与「仓库根」无法区分，因此失败单独用 `invalid` 记录。
  bool ok() const @safe pure nothrow {
    return !invalid;
  }
}

/** 从请求中取出相对 `contextPath` 的仓库资源 URI（HTTP 入口的统一 URI 防护）。

    顺序：去掉挂载前缀 → 去掉查询串 → `decodeRepositoryUri`（URL 解码，拒绝 NUL/反斜杠）→
    `segmentPath`（切段 + 点段消解）。

    解码失败、点段越界（`..` 逃出根）或与 `contextPath` 不匹配时抛 404。
    `slashEnded` 以剥掉挂载前缀后的**原始**相对 uri 为准（如 `/maven` → false、`/maven/` → true），
    服务层据此区分「目录省略尾斜杠」与「目录列表」。
    读盘服务基于 `ResourceUri.segs` 构造路径或经 `repositoryUri` 重建 uri，均已在入口消解，无需再防穿越。
*/
ResourceUri getResourceUri(string contextPath, HTTPServerRequest req) {
  auto uri = req.requestURI;
  if (contextPath != "" && contextPath != "/") {
    if (uri.startsWith(contextPath)) {
      uri = uri[contextPath.length .. $];
    } else {
      throw new HTTPStatusException(HTTPStatus.notFound);
    }
  }
  auto qIdx = uri.indexOf("?");
  if (qIdx > 0)
    uri = uri[0 .. qIdx];

  auto decoded = decodeRepositoryUri(uri);
  if (decoded is null)
    throw new HTTPStatusException(HTTPStatus.notFound);
  auto rs = segmentPath(decoded);
  if (!rs.ok)
    throw new HTTPStatusException(HTTPStatus.notFound);
  // 尾斜杠以原始请求为准：`decodeRepositoryUri` 会把空串补成 `/`，
  // 否则 `/maven`（缺尾斜杠，应重定向）会被当成 `/maven/` 直接列表。
  rs.slashEnded = uri.endsWith("/");
  return rs;
}

/** 将已解码路径切段并做点段消解（RFC 3986 remove_dot_segments）。
    跳过中间空段与 `.`；`..` 抵消前一段，弹栈越界（试图逃出根）置 `invalid`；
    全部段被消解时得到空段数组，因而仓库根（如 `/maven`、`/maven/`）是合法解析结果；
    原始路径以 `/` 结尾时 `slashEnded=true`（段数组本身不含末尾空段）。
    调用方须保证 `uri` 已由 `decodeRepositoryUri` 处理（拒绝 NUL/反斜杠）。
    实现为单次逐字节扫描：段为原始 `uri` 的切片（零拷贝），避免 `std.string.split`
    的数组与子串分配（请求热路径，微基准约省 30-40%）。 */
ResourceUri segmentPath(string uri) {
  auto slashEnded = uri.endsWith("/");
  string[] segs;
  size_t start = 0;
  foreach (i; 0 .. uri.length) {
    if (uri[i] != '/')
      continue;
    auto part = uri[start .. i];
    start = i + 1;
    if (part.length == 0 || part == ".")
      continue;
    if (part == "..") {
      if (segs.length == 0)
        return ResourceUri(null, slashEnded, true);
      segs.length--;
      continue;
    }
    segs ~= part;
  }
  auto tail = uri[start .. $];
  if (tail.length > 0) {
    if (tail == "..") {
      if (segs.length == 0)
        return ResourceUri(null, slashEnded, true);
      segs.length--;
    } else if (tail != ".") {
      segs ~= tail;
    }
  }
  return ResourceUri(segs, slashEnded);
}

/** 由 `ResourceUri` 重建仓库相对 URI（以 `/` 开头；`slashEnded` 还原尾斜杠；空段 = `/`）。 */
string repositoryUri(const ResourceUri uri) {
  if (uri.segs.length == 0)
    return "/";
  auto s = "/" ~ uri.segs.join("/");
  return uri.slashEnded ? s ~ "/" : s;
}

/** 拼出目录列表的绝对 URL 并保证以 `/` 结尾（目录重定向的目标）。

    `repositoryUri` 对仓库根固定返回 `/`，直接与端点拼接即得 `/maven/`；其余路径按
    `slashEnded` 补尾斜杠。传入缺失尾斜杠的 `uri` 亦可（根路径不会再拼成 `/maven//`）。
*/
string directoryUri(string endpoint, const ResourceUri uri) {
  auto ruri = repositoryUri(uri);
  return ruri.endsWith("/") ? endpoint ~ ruri : endpoint ~ ruri ~ "/";
}

/** 由 `ResourceUri` 的段构造绝对物理路径（须已由 `getResourceUri`/`segmentPath` 消解）。
    空段返回 `baseAbs` 本身；`baseAbs` 须为归一绝对路径（无尾斜杠）、`segs` 无 `.`/`..` 与空段，
    直接拼接即安全且比 `buildPath` 便宜（后者内部逐字符 chainPath 拷贝）。 */
string repositoryPath(string baseAbs, const ResourceUri uri) {
  if (uri.segs.length == 0)
    return baseAbs;
  return baseAbs ~ "/" ~ uri.segs.join("/");
}

/** 解码相对路径（由 `getResourceUri` 在 HTTP 入口调用；测试亦可直调）。

    - URL 解码（如 `%2e%2e` → `..`）
    - 拒绝 NUL、反斜杠
    - 保证结果以 `/` 开头

    不访问磁盘，不判断文件是否存在；失败返回 null。
*/
string decodeRepositoryUri(string uri) {
  import vibe.textfilter.urlencode : urlDecode;

  auto decoded = urlDecode(uri);
  if (decoded.indexOf('\0') >= 0 || decoded.indexOf('\\') >= 0)
    return null;
  if (decoded.length == 0 || decoded[0] != '/')
    decoded = "/" ~ decoded;
  return decoded;
}

/** 规范化仓库根目录：展开 `~`、转绝对路径并消解 `.`/`..` 段（供各仓库构造复用）。 */
string normalizeBasePath(string base) {
  auto norm = buildNormalizedPath(absolutePath(expandTilde(base)).split("/"));
  // `buildNormalizedPath` 会剥掉根斜杠（如 `/a/b` → `a/b`），绝对路径需补回根
  return norm.startsWith("/") ? norm : "/" ~ norm;
}

string resolveConfigFile(string defaultConfigFileName) {
  string config;
  auto hasConfig = readOption!string("f", &config, "specify config file, dir or URL");

  if (!hasConfig) {
    throw new Exception("-f is required. Use --help for usage.");
  }
  return resolveConfigFile(defaultConfigFileName, config);
}

/** 由显式配置值（`-f` 后的参数）解析配置路径：URL 下载到 `~/micdn.xml`、目录补 `micdn.xml`、文件取原样。
    供 `clean` 等从自有 args 数组提取 `-f` 的调用方使用（避免依赖全局 `readOption`）。 */
string resolveConfigFile(string defaultConfigFileName, string config) {
  // URL：下载到 ~/micdn.xml
  if (config.startsWith("http://") || config.startsWith("https://")) {
    auto localPath = expandTilde("~/" ~ defaultConfigFileName);
    if (curlDownload(config, localPath)) {
      return localPath;
    }
    throw new Exception("Failed to download config from " ~ config);
  }
  if (!exists(config)) {
    return config;
  }
  if (config.endsWith("/"))
    config = config[0 .. $ - 1];

  if (isDir(config)) {
    auto home = expandTilde(config);
    config = expandTilde(home ~ "/" ~ defaultConfigFileName);
  }
  fetchRemoteIfNeeded(config);
  return config;
}

/** 从 XML 文本的**根元素** `<micdn ...>` 开始标签里提取 remote 属性值，用正则避免递归解析。未找到返回 null。

    只看根元素：`<maven><snapshot remote=.../></maven>`、`<npm><dev remote=.../></npm>` 也用 `remote`
    属性，若在全文里找第一个 `remote=` 会把子元素的上游地址误当成本配置的远程地址。
 */
string extractRemoteUrl(string content) {
  auto start = content.indexOf("<micdn");
  if (start < 0)
    return null;
  auto after = start + "<micdn".length;
  if (after < content.length && !isTagBoundary(content[after]))
    return null;
  auto end = content.indexOf('>', after);
  if (end < 0)
    return null;
  auto m = matchFirst(content[start .. end], regex(r"remote\s*=\s*[\x22\x27]([^\x22\x27]+)[\x22\x27]"));
  return (m && m.captures.length > 1) ? m.captures[1] : null;
}

/// `<micdn` 之后允许的字符：空白、`>`（`<micdn>`）、`/`（`<micdn/>`）。
private bool isTagBoundary(char c) {
  return c == '>' || c == '/' || c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/** 启动或 reload 前调用：若本地配置文件含 remote 属性，则下载覆盖。
*/
void fetchRemoteIfNeeded(string configPath) {
  if (!exists(configPath))
    return;
  auto content = cast(string) read(configPath);
  auto url = extractRemoteUrl(content);
  if (url !is null) {
    curlDownload(url, configPath);
  }
}
