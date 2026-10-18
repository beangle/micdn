/* Copyright (C) 2026 Beangle
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

module micdn.remote;
/// 本地 bootstrap 配置：`micdn.conf` 的 `[remote]` 段。
///
/// `micdn.xml` 不再支持 `remote` 属性。只有 reload 会读取与 XML 同目录的 `micdn.conf`：
/// `[remote] url` 为 http/https 地址，`token` 可选，作为 `Authorization: Bearer` 发送。

import std.file : exists, read, remove, rename;
import std.path : absolutePath, buildPath, baseName, dirName, expandTilde;
import std.string : indexOf, split, startsWith, strip, toLower;
import std.conv : to;

import micdn.config : parse;
import micdn.model : MicdnConfig;
import micdn.web.curl : isValidBearerToken, curlDownload;
import micdn.xml : MicdnXmlException, readXml;

/// `[remote]` 段配置；`url` 为空表示不启用远程配置。
struct RemoteConfig {
  string url;
  string token;

  bool active() const {
    return url.length > 0;
  }
}

/// 与 `micdn.xml` 同目录的 `micdn.conf`。
string remoteConfigPath(string xmlPath) {
  return buildPath(dirName(absolutePath(expandTilde(xmlPath))), "micdn.conf");
}

/// 读取 `micdn.conf`。文件不存在或没有 `[remote] url` 时返回空配置，
/// 此时 reload 只重新解析本地 `micdn.xml`。
RemoteConfig loadRemoteConfig(string xmlPath) {
  auto conf = remoteConfigPath(xmlPath);
  if (!exists(conf))
    return RemoteConfig.init;
  return parseRemoteConfig(cast(string) read(conf), conf);
}

/// 解析 INI 文本。只识别 `[remote]` 段的 `url` / `token`；其他段忽略，
/// 但 `url` / `token` 写错位置或 `[remote]` 内出现未知键会报错。
RemoteConfig parseRemoteConfig(string content, string source = "micdn.conf") {
  RemoteConfig rc;
  string section;
  size_t lineNo;
  foreach (raw; content.split('\n')) {
    lineNo++;
    auto line = raw.strip;
    if (line.length == 0 || line[0] == '#' || line[0] == ';')
      continue;
    if (line[0] == '[') {
      auto end = line.indexOf(']');
      if (end < 0)
        throw new Exception(source ~ ":" ~ lineNo.to!string ~ ": invalid section header");
      section = line[1 .. end].strip.toLower;
      continue;
    }
    auto eq = line.indexOf('=');
    if (eq < 0)
      throw new Exception(source ~ ":" ~ lineNo.to!string ~ ": expected key=value");
    auto key = line[0 .. eq].strip.toLower;
    auto value = line[eq + 1 .. $].strip;
    if (value.length >= 2 && ((value[0] == '"' && value[$ - 1] == '"')
        || (value[0] == '\'' && value[$ - 1] == '\'')))
      value = value[1 .. $ - 1];
    if (section != "remote") {
      if (key == "url" || key == "token")
        throw new Exception(source ~ ":" ~ lineNo.to!string ~ ": " ~ key ~ " must be in the [remote] section");
      continue;
    }
    if (key == "url")
      rc.url = value;
    else if (key == "token")
      rc.token = value;
    else
      throw new Exception(source ~ ":" ~ lineNo.to!string ~ ": unknown key in [remote]: " ~ key);
  }
  validateRemoteConfig(rc, source);
  return rc;
}

private void validateRemoteConfig(RemoteConfig rc, string source) {
  if (rc.url.length == 0)
    return;
  auto lower = rc.url.toLower;
  if (!lower.startsWith("http://") && !lower.startsWith("https://"))
    throw new Exception(source ~ ": [remote] url must use http:// or https://");
  if (rc.token.length > 0 && !isValidBearerToken(rc.token))
    throw new Exception(source ~ ": [remote] token contains an invalid character");
}

/// reload 时下载远程配置：先落到同目录临时文件，解析校验通过后再覆盖 `micdn.xml`。
/// 下载或解析失败会抛异常，调用方保留旧 router 继续服务。
MicdnConfig fetchRemoteConfig(RemoteConfig rc, string xmlPath) {
  auto target = absolutePath(expandTilde(xmlPath));
  auto tmp = buildPath(dirName(target), "." ~ baseName(target) ~ ".remote");
  scope (exit) {
    if (exists(tmp))
      remove(tmp);
  }
  if (!curlDownload(rc.url, tmp, rc.token))
    throw new Exception("Failed to download remote config: " ~ rc.url);

  MicdnConfig config;
  try {
    config = parse(dirName(target), readXml(tmp), target);
  } catch (MicdnXmlException e) {
    throw e;
  } catch (Exception e) {
    throw new MicdnXmlException(target ~ ": " ~ e.msg);
  }
  rename(tmp, target);
  return config;
}
