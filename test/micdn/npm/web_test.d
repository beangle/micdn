/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.npm.web_test;

import std.algorithm : canFind;
import std.conv : to;
import std.file;
import std.path : absolutePath, buildPath;
import std.socket : parseAddress;
import std.uuid : randomUUID;

import vibe.core.net : NetworkAddress;
import vibe.http.common : HTTPMethod, HTTPStatus, HTTPStatusException;
import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse, TestHTTPResponseMode;
import vibe.inet.message : InetHeaderMap;
import vibe.inet.url : URL;
import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;

import micdn.config : parseFile;
import micdn.model : MicdnConfig;
import micdn.npm : NpmRepo;
import micdn.npm.web : NpmService;

private string npmHome() {
  auto home = absolutePath(buildPath(tempDir, "micdn_npm_web_" ~ randomUUID().toString));
  mkdirRecurse(buildPath(home, "npm", "@xurp"));
  return home;
}

private string npmConfig(string home) {
  auto xmlPath = buildPath(home, "micdn.xml");
  write(xmlPath, `<?xml version="1.0"?><micdn listen="127.0.0.1:8888">
  <maven/><npm base="` ~ buildPath(home, "npm") ~ `"/>
</micdn>`);
  return xmlPath;
}

private string packumentBody(string home, string body) {
  auto path = buildPath(home, "npm", "@xurp", "manual");
  write(path, body);
  return path;
}

private string fetch(string xmlPath, string host) {
  InetHeaderMap headers;
  headers["Host"] = host;
  auto service = new NpmService(parseFile(xmlPath));
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://" ~ host ~ "/npm/@xurp/manual"),
      HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  service.service(req, res);
  return cast(string) output.data;
}

@("npm packument delivery substitutes {origin} with the request origin")
unittest {
  auto home = npmHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  packumentBody(home, `{"name":"@xurp/manual","versions":{"0.0.4":{"dist":{` ~
      `"tarball":"{origin}/npm/@xurp/manual/-/manual-0.0.4.tgz"}}}}`);
  auto xmlPath = npmConfig(home);

  auto body = fetch(xmlPath, "cdn.example.com:8443");
  assert(body.canFind("http://cdn.example.com:8443/npm/@xurp/manual/-/manual-0.0.4.tgz"), body);
  assert(!body.canFind("{origin}"), "placeholder must be gone: " ~ body);

  InetHeaderMap headers;
  headers["Host"] = "10.0.0.5:8888";
  headers["X-Forwarded-Host"] = "cdn.example.com";
  headers["X-Forwarded-Proto"] = "https";
  auto service = new NpmService(parseFile(xmlPath));
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://10.0.0.5:8888/npm/@xurp/manual"),
      HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  service.service(req, res);
  assert((cast(string) output.data).canFind("https://cdn.example.com/npm/@xurp/manual/-/manual-0.0.4.tgz"));
  assert(res.headers["Content-Type"] == "application/json; charset=utf-8");
  assert(res.headers["Cache-Control"] == "public, no-cache");
  assert(res.headers["Etag"].length > 0, "packument keeps a validator");
}

@("npm packument delivery leaves upstream absolute tarball urls untouched")
unittest {
  auto home = npmHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  packumentBody(home, `{"name":"@xurp/manual","versions":{"0.0.4":{"dist":{` ~
      `"tarball":"https://registry.npmmirror.com/@xurp/manual/-/manual-0.0.4.tgz"}}}}`);
  auto xmlPath = npmConfig(home);

  auto body = fetch(xmlPath, "cdn.example.com");
  assert(body.canFind("https://registry.npmmirror.com/@xurp/manual/-/manual-0.0.4.tgz"));
  assert(!body.canFind("cdn.example.com"), "upstream metadata must not be rewritten: " ~ body);
}

@("npm packument delivery answers 304 for a matching If-None-Match")
unittest {
  auto home = npmHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  packumentBody(home, `{"name":"@xurp/manual","versions":{}}`);
  auto xmlPath = npmConfig(home);
  auto service = new NpmService(parseFile(xmlPath));

  InetHeaderMap headers;
  headers["Host"] = "cdn.example.com";
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://cdn.example.com/npm/@xurp/manual"),
      HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  service.service(req, res);
  auto etag = res.headers["Etag"];
  assert(etag.length > 0);

  InetHeaderMap conditional;
  conditional["Host"] = "cdn.example.com";
  conditional["If-None-Match"] = etag;
  auto output2 = createMemoryOutputStream();
  auto req2 = createTestHTTPServerRequest(URL("http://cdn.example.com/npm/@xurp/manual"),
      HTTPMethod.GET, conditional, null);
  auto res2 = createTestHTTPServerResponse(output2, null, TestHTTPResponseMode.bodyOnly);
  service.service(req2, res2);
  assert(res2.statusCode == HTTPStatus.notModified);
  assert(output2.data.length == 0);
}

@("npm packument answers HEAD with the substituted body length")
unittest {
  auto home = npmHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  packumentBody(home, `{"name":"@xurp/manual","versions":{"0.0.4":{"dist":{` ~
      `"tarball":"{origin}/npm/@xurp/manual/-/manual-0.0.4.tgz"}}}}`);
  auto xmlPath = npmConfig(home);
  auto service = new NpmService(parseFile(xmlPath));

  InetHeaderMap headers;
  headers["Host"] = "cdn.example.com";
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://cdn.example.com/npm/@xurp/manual"),
      HTTPMethod.HEAD, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  service.service(req, res);

  // 长度按替换后的正文计算（真实服务器对 HEAD 只发头部、不发正文；测试替身统一落到 sink）
  immutable expected = `{"name":"@xurp/manual","versions":{"0.0.4":{"dist":{` ~
    `"tarball":"http://cdn.example.com/npm/@xurp/manual/-/manual-0.0.4.tgz"}}}}`;
  assert(res.statusCode == HTTPStatus.ok);
  assert(res.headers["Content-Type"] == "application/json; charset=utf-8");
  assert(res.headers["Content-Length"] == expected.length.to!string);
  assert((cast(string) output.data) == expected);
}

@("npm serves dev versions from the same /npm mount, sharing the release base")
unittest {
  auto home = npmHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  // 开发版 packument 与正式版一样落在 `<npm base>`（`micdn install` 的产物），/npm 是唯一入口
  packumentBody(home, `{"name":"@xurp/manual","versions":{"0.0.4-dev.2":{"dist":{` ~
      `"tarball":"{origin}/npm/@xurp/manual/-/manual-0.0.4-dev.2.tgz"}}}}`);
  auto xmlPath = npmConfig(home);
  auto config = parseFile(xmlPath);
  auto repo = NpmRepo.build(config);
  assert(repo.devRemote.length == 0, "没配 <dev remote=...> 时开发版不代理上游");

  InetHeaderMap headers;
  headers["Host"] = "cdn.example.com";
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://cdn.example.com/npm/@xurp/manual"),
      HTTPMethod.GET, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  new NpmService(config).service(req, res);

  auto body = cast(string) output.data;
  assert(body.canFind("http://cdn.example.com/npm/@xurp/manual/-/manual-0.0.4-dev.2.tgz"), body);
  assert(!body.canFind("{origin}"), body);
  assert(res.headers["Content-Type"] == "application/json; charset=utf-8");
}

// ---- 发布（PUT）：令牌闸门 ----

private struct PublishOutcome {
  int status;
  string body;
  string authenticate;
}

/// 发一个 PUT 到 `/npm/@xurp/manual`：`peer` 为空表示不设对端（即空 peer，非环回）。
/// `authorization` 走 `Authorization` 头（Bearer/Basic），`xToken` 走 `X-Micdn-Token`。
private PublishOutcome npmPut(MicdnConfig config, string peer, string authorization, string body,
    string xToken = "") {
  InetHeaderMap headers;
  headers["Host"] = "localhost";
  if (authorization.length > 0)
    headers["Authorization"] = authorization;
  if (xToken.length > 0)
    headers["X-Micdn-Token"] = xToken;
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://localhost/npm/@xurp/manual"), HTTPMethod.PUT,
      headers, createMemoryStream(cast(ubyte[]) body));
  if (peer.length > 0)
    req.clientAddress = NetworkAddress(parseAddress(peer, 12345));
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  try {
    new NpmService(config).service(req, res);
  } catch (HTTPStatusException e) {
    // 真实服务器上由 vibe 的错误处理把抛出的异常转成状态码（测试替身没有这一层）
    return PublishOutcome(e.status, "", "");
  }
  return PublishOutcome(res.statusCode, cast(string) output.data,
      res.headers.get("WWW-Authenticate", ""));
}

private string publishConfig(string home, string publishElement) {
  auto xmlPath = buildPath(home, "micdn.xml");
  write(xmlPath, `<?xml version="1.0"?><micdn listen="127.0.0.1:8888">
  <maven/><npm base="` ~ buildPath(home, "npm") ~ `"/>` ~ publishElement ~ `
</micdn>`);
  return xmlPath;
}

@("npm PUT requires the publish token")
unittest {
  auto home = npmHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto config = parseFile(publishConfig(home, `<publish token="s3cret"/>`));

  // 缺令牌：401 且带 Basic 挑战（Maven 靠它重试）；写完响应即返回，不看 body
  auto missing = npmPut(config, "127.0.0.1", "", "x");
  assert(missing.status == HTTPStatus.unauthorized);
  assert(missing.authenticate.canFind("Basic"), missing.authenticate);

  auto wrong = npmPut(config, "127.0.0.1", "Bearer nope", "x");
  assert(wrong.status == HTTPStatus.unauthorized);

  // 令牌正确就放行，来源地址无关（远端开发机带令牌直接推）：body 不是 publish 文档 → 400
  auto badBody = npmPut(config, "127.0.0.1", "Bearer s3cret", "not-json");
  assert(badBody.status == HTTPStatus.badRequest, badBody.status.to!string);

  auto remote = npmPut(config, "192.168.1.5", "Bearer s3cret", "not-json");
  assert(remote.status == HTTPStatus.badRequest, remote.status.to!string);

  auto viaHeader = npmPut(config, "::1", "", "not-json", "s3cret");
  assert(viaHeader.status == HTTPStatus.badRequest, viaHeader.status.to!string);
}

@("npm PUT stays closed when <publish> is absent")
unittest {
  auto home = npmHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  // 未声明 <publish>：服务端令牌为空，即便带上令牌也一律 401（路由层也不会注册 PUT）
  auto config = parseFile(publishConfig(home, ""));
  auto outcome = npmPut(config, "127.0.0.1", "Bearer s3cret", "x");
  assert(outcome.status == HTTPStatus.unauthorized, outcome.status.to!string);
}
