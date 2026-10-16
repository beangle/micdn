/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.maven.web_test;

import std.algorithm : canFind;
import std.exception : collectException;
import std.file;
import std.path : absolutePath, buildPath;
import std.uuid : randomUUID;

import vibe.http.common : HTTPMethod, HTTPStatus, HTTPStatusException;
import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse,
    TestHTTPResponseMode;
import vibe.inet.message : InetHeaderMap;
import vibe.inet.url : URL;
import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;

import micdn.config : parseFile;
import micdn.maven.web : MavenService;

private string mavenHome() {
  auto home = absolutePath(buildPath(tempDir, "micdn_maven_web_" ~ randomUUID().toString));
  mkdirRecurse(buildPath(home, "m2"));
  return home;
}

/// 上游指到本地空目录（`file://`）：万一有未预期的回源也是本地失败，不会去碰外网。
private string mavenConfig(string home, string extraElements = "") {
  auto xmlPath = buildPath(home, "micdn.xml");
  write(xmlPath, `<?xml version="1.0"?><micdn listen="127.0.0.1:8888">
  <maven base="` ~ buildPath(home, "m2") ~ `">
    <remote url="file://` ~ buildPath(home, "upstream") ~ `"/>
  </maven>` ~ extraElements ~ `
</micdn>`);
  return xmlPath;
}

private struct Exchange {
  HTTPStatus status;
  string body;
  string cacheControl;
  string authenticate;
}

private Exchange exchange(string xmlPath, string url, HTTPMethod method,
    string[string] extraHeaders = null, string body = null) {
  InetHeaderMap headers;
  headers["Host"] = "cdn.example.com";
  foreach (k, v; extraHeaders)
    headers[k] = v;
  auto service = new MavenService(parseFile(xmlPath));
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://cdn.example.com" ~ url), method, headers,
      body is null ? null : createMemoryStream(cast(ubyte[]) body));
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  auto err = collectException!HTTPStatusException(service.service(req, res));
  return Exchange(cast(HTTPStatus)(err is null ? res.statusCode : err.status), cast(string) output.data,
      res.headers.get("Cache-Control", ""), res.headers.get("WWW-Authenticate", ""));
}

@("maven download-key gates artifact and metadata GETs but not HEAD or listings")
unittest {
  auto home = mavenHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto xmlPath = mavenConfig(home, `  <auth download-key="r5"/>`);
  auto jarPath = buildPath(home, "m2", "org", "beangle", "tool", "1.0.0", "tool-1.0.0.jar");
  mkdirRecurse(buildPath(home, "m2", "org", "beangle", "tool", "1.0.0"));
  write(jarPath, "jar-bytes");

  const jar = "/maven/org/beangle/tool/1.0.0/tool-1.0.0.jar";

  // 无凭据：401 + Basic 挑战 + no-store
  auto anon = exchange(xmlPath, jar, HTTPMethod.GET);
  assert(anon.status == HTTPStatus.unauthorized);
  assert(anon.authenticate.canFind("Basic"));
  assert(anon.cacheControl == "no-store");

  // 本地缺失的构件同样 401（先鉴权、后回源）：既无存在性泄露，也不会为未授权请求抓取上游
  auto absent = exchange(xmlPath, "/maven/org/beangle/tool/9.9.9/tool-9.9.9.jar", HTTPMethod.GET);
  assert(absent.status == HTTPStatus.unauthorized);
  assert(!exists(buildPath(home, "m2", "org", "beangle", "tool", "9.9.9")));

  // 元数据（文件型路径）同样受限
  assert(exchange(xmlPath, "/maven/org/beangle/tool/maven-metadata.xml", HTTPMethod.GET).status
      == HTTPStatus.unauthorized);

  // 带凭据放行，受限响应降级为 private
  auto ok = exchange(xmlPath, jar, HTTPMethod.GET, ["Authorization": "Bearer r5"]);
  assert(ok.status == HTTPStatus.ok && ok.body == "jar-bytes");
  assert(ok.cacheControl == "private, max-age=31536000, immutable", ok.cacheControl);
  // 凭据头的三种形态等价（X-Micdn-Token 供不方便改 Authorization 的客户端使用）
  auto viaHeader = exchange(xmlPath, jar, HTTPMethod.GET, ["X-Micdn-Token": "r5"]);
  assert(viaHeader.status == HTTPStatus.ok && viaHeader.body == "jar-bytes");

  // HEAD 不设限：boot 的 `Repo.Remote.exists`（HttpUtils.isAlive）与快照别名探测都靠它
  assert(exchange(xmlPath, jar, HTTPMethod.HEAD).status == HTTPStatus.ok);

  // 目录列表与补尾斜杠的 302 不设限
  assert(exchange(xmlPath, "/maven/org/beangle/tool/1.0.0/", HTTPMethod.GET).status == HTTPStatus.ok);
  // 不带尾斜杠的目录路径按「文件型 URI」判定（先鉴权、后 stat）：未授权 401，带上凭据才 302 补 `/`
  assert(exchange(xmlPath, "/maven/org/beangle/tool/1.0.0", HTTPMethod.GET).status
      == HTTPStatus.unauthorized);
  assert(exchange(xmlPath, "/maven/org/beangle/tool/1.0.0", HTTPMethod.GET,
      ["Authorization": "Bearer r5"]).status == HTTPStatus.found);

  // 未配置 download-key 时读路径与缓存策略都保持原样
  auto openXml = mavenConfig(home);
  auto open = exchange(openXml, jar, HTTPMethod.GET);
  assert(open.status == HTTPStatus.ok && open.cacheControl == "public, max-age=31536000, immutable");

  // 写：download-key 不授予写权限，PUT 仍只看 publish-key
  assert(exchange(xmlPath, jar, HTTPMethod.PUT, null, "x").status == HTTPStatus.unauthorized);
  auto writeXml = mavenConfig(home, `  <auth publish-key="w5" download-key="r5"/>`);
  assert(exchange(writeXml, jar, HTTPMethod.PUT, ["Authorization": "Bearer w5"], "x").status
      == HTTPStatus.created);
  assert(exchange(writeXml, jar, HTTPMethod.PUT, ["Authorization": "Bearer r5"], "x").status
      == HTTPStatus.unauthorized);
}
