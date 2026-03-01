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
import std.typecons;

import dxml.dom;

import vibe.core.args;
import vibe.core.log;

import micdn.web.file;
import micdn.xml;

class ServerOptions {
  string[] ips;
  ushort port;
  string contextPath;

  this(string[] ips, ushort port, string contextPath) {
    this.ips = ips;
    this.port = port;
    this.contextPath = contextPath;
  }

  public static ServerOptions parse(string content) {
    auto dom = parseDOM!simpleXML(content).children[0];
    auto attrs = getAttrs(dom);
    string hosts;
    if ("ips" in attrs) {
      hosts = attrs.get("ips", "127.0.0.1");
    } else {
      hosts = attrs.get("hosts", "127.0.0.1");
    }
    ushort p = attrs.get("port", "8080").to!ushort;
    auto contextEntries = children(dom, "Context");
    if (contextEntries.empty) {
      throw new Exception("Context element is needed in server.xml.");
    }
    auto contextAttrs = getAttrs(contextEntries.front);
    return new ServerOptions(split(hosts, ","), p, contextAttrs["path"]);
  }

  @property public string listenAddr() const {
    return this.ips[0] ~ ":" ~ port.to!string;
  }

}

string readConfig(string defaultHome, string defaultConfigFileName) {
  string config;
  string remoteDir;
  auto hasConfig = readOption!string("config|f", &config, "specify config params");
  auto hasRemote = readOption!string("remote|r", &remoteDir, "specify remote params");

  if (!hasConfig) {
    throw new Exception("--config/-f is required. Use --help for usage.");
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
  if (hasRemote) {
    auto newxml = config ~ ".new";
    auto remoteUrl = remoteDir ~ "/" ~ defaultConfigFileName;
    if (curlDownload(remoteUrl, newxml)) {
      logInfo("Downloaded %s", remoteUrl);
      rename(newxml, config);
    }
  }
  return config;
}

ServerOptions getServerOptions() {
  string serverFile;
  auto success = readOption!string("server", &serverFile, "specify server params");
  if (success) {
    if (exists(serverFile)) {
      return ServerOptions.parse(cast(string) read(serverFile));
    } else {
      throw new Exception(serverFile ~ " is not exists!");
    }
  } else {
    auto defaultConfig = `<?xml version="1.0" encoding="UTF-8"?><Server ips="127.0.0.1" port="8080">`
      ~ `<Context path="/"/></Server>`;
    return ServerOptions.parse(defaultConfig);
  }
}
