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
import vibe.core.log;
import vibe.http.server;

import micdn.fs.file : isPathUnder;
import micdn.web.file;
import micdn.xml;

/** 从请求中取出相对 `contextPath` 的路径（HTTP 入口的统一 URI 防护）。

    顺序：去掉挂载前缀 → 去掉查询串 → `decodeRepositoryUri`（URL 解码，拒绝 NUL/反斜杠）。

    不判断文件是否存在；解码失败或与 `contextPath` 不匹配时抛 404。
    读盘服务随后应再调用 `resolveRepositoryPath` 限制在仓库 `base` 下。
*/
string getPath(string contextPath, HTTPServerRequest req) {
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
  return decoded;
}

/** 解码相对路径（由 `getPath` 在 HTTP 入口调用；测试亦可直调）。

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

/** 将已解码 URI 规范化为仓库内的绝对物理路径（防路径穿越）。

    流程：`base` 转绝对路径 → 与 URI 相对段做 `buildNormalizedPath` → `isPathUnder` 校验。

    注意：
    - **不**调用 `exists` / `isFile` / `isDir`；路径在磁盘上不存在时仍可返回非 null。
    - 越界（规范化后逃出 `base`）或 `decodedUri == null` 时返回 null。

    调用方在拿到返回值后须自行判断是否存在，并按模块语义处理（404、拉取上游、目录列表等）。
*/
string resolveRepositoryPath(string base, string decodedUri) {
  if (decodedUri is null)
    return null;
  auto baseAbs = absolutePath(expandTilde(base));
  string relative = decodedUri;
  while (relative.startsWith("/"))
    relative = relative[1 .. $];

  auto path = absolutePath(buildNormalizedPath(baseAbs, relative));
  return isPathUnder(baseAbs, path) ? path : null;
}

string resolveConfigFile(string defaultConfigFileName) {
  string config;
  auto hasConfig = readOption!string("f", &config, "specify config file, dir or URL");

  if (!hasConfig) {
    throw new Exception("-f is required. Use --help for usage.");
  }
  // URL：下载到 ~/micdn.xml
  if (config.startsWith("http://") || config.startsWith("https://")) {
    auto localPath = expandTilde("~/" ~ defaultConfigFileName);
    if (curlDownload(config, localPath)) {
      logInfo("Downloaded %s -> %s", config, localPath);
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

/** 从 XML 文本中提取 remote 属性值，用正则避免递归解析。未找到返回 null。
 */
string extractRemoteUrl(string content) {
  auto m = matchFirst(content, regex(r"remote\s*=\s*[\x22\x27]([^\x22\x27]+)[\x22\x27]"));
  return (m && m.captures.length > 1) ? m.captures[1] : null;
}

/** 启动或 reload 前调用：若本地配置文件含 remote 属性，则下载覆盖。
*/
void fetchRemoteIfNeeded(string configPath) {
  if (!exists(configPath))
    return;
  auto content = cast(string) read(configPath);
  auto url = extractRemoteUrl(content);
  if (url !is null) {
    if (curlDownload(url, configPath)) {
      logInfo("Downloaded config from %s -> %s", url, configPath);
    }
  }
}
