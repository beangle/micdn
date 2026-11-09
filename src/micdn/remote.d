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

/// 远程配置：`BAS_PRINCIPAL=project@url` + `BAS_TOKEN=...`。
///
/// 不再读取 `micdn.conf`。启动和 reload 都从环境变量取配置；没有配置时使用本地
/// `micdn.xml`，配置不完整或下载失败都直接报错，不做本地 fallback。

import std.file : exists, remove, rename;
import std.path : absolutePath, baseName, buildPath, dirName, expandTilde;
import std.process : environment;
import std.string : indexOf, startsWith, strip, stripRight, toLower;

import micdn.config : parse;
import micdn.model : MicdnConfig;
import micdn.web.curl : isValidBearerToken, curlDownload;
import micdn.xml : MicdnXmlException, readXml;

/// 从进程环境读取远程配置；两项都为空表示本地模式。
struct RemoteConfig {
  string url;
  string project;
  string token;

  bool active() const {
    return url.length > 0;
  }
}

/// 读取 `BAS_PRINCIPAL` / `BAS_TOKEN`。
RemoteConfig loadRemoteEnvironment() {
  auto principal = environment.get("BAS_PRINCIPAL", "").strip;
  auto token = environment.get("BAS_TOKEN", "").strip;
  return parseRemoteEnvironment(principal, token);
}

/// 解析 `project@url`；project 不能含 `/`、`@`、空白，URL 必须是 http(s)。
RemoteConfig parseRemoteEnvironment(string principal, string token) {
  auto value = principal.strip;
  auto secret = token.strip;
  if (value.length == 0 && secret.length == 0)
    return RemoteConfig.init;
  if (value.length == 0 || secret.length == 0)
    throw new Exception("BAS_PRINCIPAL and BAS_TOKEN must be set together");
  auto at = value.indexOf('@');
  if (at <= 0 || at == value.length - 1)
    throw new Exception("BAS_PRINCIPAL must be project@url");
  auto project = value[0 .. at].strip;
  auto url = value[at + 1 .. $].strip;
  if (project.length == 0 || project.indexOf('/') >= 0 || project.indexOf('@') >= 0
      || project.indexOf(' ') >= 0)
    throw new Exception("BAS_PRINCIPAL project must be org.name");
  auto lower = url.toLower;
  if (!lower.startsWith("http://") && !lower.startsWith("https://"))
    throw new Exception("BAS_PRINCIPAL url must use http:// or https://");
  if (!isValidBearerToken(secret))
    throw new Exception("BAS_TOKEN contains an invalid character");
  return RemoteConfig(url, project, secret);
}

/// 下载远程配置：先落到同目录临时文件，解析校验通过后再覆盖 `micdn.xml`。
/// 下载或解析失败会抛异常，调用方保留旧 router 继续服务。
MicdnConfig fetchRemoteConfig(RemoteConfig rc, string xmlPath) {
  auto target = absolutePath(expandTilde(xmlPath));
  auto tmp = buildPath(dirName(target), "." ~ baseName(target) ~ ".remote");
  scope (exit) {
    if (exists(tmp))
      remove(tmp);
  }
  auto url = rc.url.strip.stripRight("/") ~ "/api/bashub/micdn/" ~ rc.project ~ "/micdn.xml";
  if (!curlDownload(url, tmp, rc.token))
    throw new Exception("Failed to download remote config: " ~ url);

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
