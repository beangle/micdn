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

module micdn.web.server;
/// 通用 HTTP 服务器配置解析（监听地址、端口、上下文路径等）。

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

import micdn.web.file;
import micdn.xml;

/// 解码仓库请求 URI，并拒绝 NUL 与反斜杠，避免编码后的路径分隔符绕过上层检查。
string decodeRepositoryUri(string uri) {
  import vibe.textfilter.urlencode : urlDecode;

  auto decoded = urlDecode(uri);
  if (decoded.indexOf('\0') >= 0 || decoded.indexOf('\\') >= 0)
    return null;
  if (decoded.length == 0 || decoded[0] != '/')
    decoded = "/" ~ decoded;
  return decoded;
}

/// 将已解码 URI 规范化为物理路径；若规范化后不在仓库 base 下，则返回 null。
string resolveRepositoryPath(string base, string decodedUri) {
  if (decodedUri is null)
    return null;
  auto baseAbs = absolutePath(expandTilde(base));
  string relative = decodedUri;
  while (relative.startsWith("/"))
    relative = relative[1 .. $];

  auto path = absolutePath(buildNormalizedPath(baseAbs, relative));
  return pathIsUnderDir(baseAbs, path) ? path : null;
}

/// 判断规范化后的路径是否仍位于指定目录内；Windows 下路径比较不区分大小写。
private bool pathIsUnderDir(const string absDir, const string absPath) {
  import std.path : dirSeparator;
  version (Windows) {
    auto dir = absDir.toLower();
    auto path = absPath.toLower();
  } else {
    auto dir = absDir;
    auto path = absPath;
  }

  if (path == dir)
    return true;
  if (path.length <= dir.length)
    return false;
  if (path[dir.length] != dirSeparator[0])
    return false;
  return path.startsWith(dir);
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
