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

module test.micdn.native.web_test;

import std.algorithm : canFind;
import std.conv : to;
import std.exception : collectException;
import std.file;
import std.path : buildPath;
import std.string : endsWith, lastIndexOf;
import std.uuid : randomUUID;

import vibe.http.common : HTTPMethod, HTTPStatus, HTTPStatusException;
import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse, HTTPServerResponse,
    TestHTTPResponseMode;
import vibe.inet.message : InetHeaderMap;
import vibe.inet.url : URL;
import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;

import micdn.config : parseFile;
import micdn.model : MicdnConfig;
import micdn.native.web : NativeService;

private string nativeHome() {
  auto home = buildPath(tempDir, "micdn_native_" ~ randomUUID().toString);
  mkdirRecurse(home);
  return home;
}

private string nativeConfig(string home, string extraElements = "") {
  auto xmlPath = buildPath(home, "micdn.xml");
  write(xmlPath, `<?xml version="1.0"?><micdn listen="127.0.0.1:8888">
  <native base="` ~ buildPath(home, "native") ~ `"/>` ~ extraElements ~ `
</micdn>`);
  return xmlPath;
}

private struct Exchange {
  string body;
  HTTPServerResponse res;
}

/// 调用 handler（Host 固定 `cdn.example.com`），捕获 HTTPStatusException；正常返回时 error 为 null。
private Exchange exchange(MicdnConfig config, string url, HTTPMethod method, out HTTPStatusException error,
    string[string] extraHeaders = null, string body = null) {
  InetHeaderMap headers;
  headers["Host"] = "cdn.example.com";
  foreach (k, v; extraHeaders)
    headers[k] = v;
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://cdn.example.com" ~ url), method, headers,
      body is null ? null : createMemoryStream(cast(ubyte[]) body));
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  error = collectException!HTTPStatusException(new NativeService(config).service(req, res));
  return Exchange(cast(string) output.data, res);
}

/// 在本地仓库写入一个文件（测试造数据，不经过 HTTP）。
private void seed(string home, string ruri, string content) {
  auto path = buildPath(home, "native") ~ ruri;
  mkdirRecurse(path[0 .. path.lastIndexOf('/')]);
  write(path, content);
}

@("native PUT requires the publish token and stores the artifact at the request path")
unittest {
  auto home = nativeHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto config = parseFile(nativeConfig(home, `<publish token="s3cret"/>`));
  auto ruri = "/org/beangle/ems/portal/4.20.14-SNAPSHOT/portal-4.20.14-SNAPSHOT-linux-amd64.tar.gz";

  // 缺令牌：401 且带 Basic 挑战（Maven/curl 靠它重试）
  HTTPStatusException err;
  auto missing = exchange(config, "/native" ~ ruri, HTTPMethod.PUT, err, null, "tar-bytes");
  assert(err is null);
  assert(missing.res.statusCode == HTTPStatus.unauthorized);
  assert(missing.res.headers.get("WWW-Authenticate", "").canFind("Basic"));

  auto wrong = exchange(config, "/native" ~ ruri, HTTPMethod.PUT, err,
      ["Authorization": "Bearer nope"], "tar-bytes");
  assert(wrong.res.statusCode == HTTPStatus.unauthorized);

  // 令牌正确（Bearer）：201，落盘路径 = 请求路径（全路径 URL，不用 query string）
  auto ok = exchange(config, "/native" ~ ruri, HTTPMethod.PUT, err,
      ["Authorization": "Bearer s3cret"], "tar-bytes");
  assert(ok.res.statusCode == HTTPStatus.created, ok.res.statusCode.to!string);
  assert(readText(buildPath(home, "native") ~ ruri) == "tar-bytes");
  // 临时文件不残留
  assert(!exists(buildPath(home, "native") ~ ruri ~ ".incoming"));

  // X-Micdn-Token 同样可用；覆盖同名文件（开发版反复重发）
  auto viaHeader = exchange(config, "/native" ~ ruri, HTTPMethod.PUT, err,
      ["X-Micdn-Token": "s3cret"], "second");
  assert(viaHeader.res.statusCode == HTTPStatus.created);
  assert(readText(buildPath(home, "native") ~ ruri) == "second");

  // 目录路径（尾斜杠）不构成文件：400
  auto dirPut = exchange(config, "/native/org/beangle/", HTTPMethod.PUT, err,
      ["Authorization": "Bearer s3cret"], "x");
  assert(err !is null && err.status == HTTPStatus.badRequest, err is null ? "no error" : err.msg);
}

@("native serves files, lists directories and redirects to the trailing slash")
unittest {
  auto home = nativeHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto config = parseFile(nativeConfig(home));
  seed(home, "/org/beangle/ems/portal/4.20.13/portal-4.20.13-linux-amd64.tar.gz", "dist");

  HTTPStatusException err;
  auto file = exchange(config, "/native/org/beangle/ems/portal/4.20.13/portal-4.20.13-linux-amd64.tar.gz",
      HTTPMethod.GET, err);
  assert(err is null);
  assert(file.res.statusCode == HTTPStatus.ok);
  assert(file.body == "dist");

  auto head = exchange(config, "/native/org/beangle/ems/portal/4.20.13/portal-4.20.13-linux-amd64.tar.gz",
      HTTPMethod.HEAD, err);
  assert(err is null && head.res.statusCode == HTTPStatus.ok);

  // 目录：缺尾斜杠 302 补 `/`，带上尾斜杠列出内容
  auto dir = exchange(config, "/native/org/beangle/ems/portal/4.20.13", HTTPMethod.GET, err);
  assert(err is null);
  assert(dir.res.statusCode == HTTPStatus.found);
  assert(dir.res.headers["Location"] == "/native/org/beangle/ems/portal/4.20.13/");

  auto list = exchange(config, "/native/org/beangle/ems/portal/4.20.13/", HTTPMethod.GET, err);
  assert(err is null && list.res.statusCode == HTTPStatus.ok);
  assert(list.body.canFind("portal-4.20.13-linux-amd64.tar.gz"), list.body);

  // 仓库根也是目录列表（GET /native 先补斜杠）
  auto root = exchange(config, "/native", HTTPMethod.GET, err);
  assert(err is null && root.res.statusCode == HTTPStatus.found);
  assert(root.res.headers["Location"] == "/native/");

  // 缺失文件 404；目录 HEAD 405（与 /maven 同口径）
  auto missing = exchange(config, "/native/org/beangle/ems/portal/9.9.9/x.tar.gz", HTTPMethod.GET, err);
  assert(err !is null && err.status == HTTPStatus.notFound);
  exchange(config, "/native/org/beangle/ems/portal/4.20.13/", HTTPMethod.HEAD, err);
  assert(err !is null && err.status == HTTPStatus.methodNotAllowed);
}

@("native resolves an untimestamped delta alias to the newest timestamped build")
unittest {
  auto home = nativeHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto config = parseFile(nativeConfig(home));
  auto dir = "/org/beangle/ems/portal/4.20.14-SNAPSHOT";
  // 发行包（开发版同名覆盖）：没有时间戳，直接取文件
  seed(home, dir ~ "/portal-4.20.14-SNAPSHOT-linux-amd64.tar.gz", "dist");
  // 增量补丁带时间戳：构建号按数字比，`-10` 比 `-9` 新，且时间戳更晚者优先
  auto older = "/portal-4.20.13_4.20.14-SNAPSHOT-20260913.101500-9-linux-amd64.tar.gz.diff";
  auto newer = "/portal-4.20.13_4.20.14-SNAPSHOT-20260913.101500-10-linux-amd64.tar.gz.diff";
  seed(home, dir ~ older, "old-diff");
  seed(home, dir ~ newer, "new-diff");
  seed(home, dir ~ older ~ ".sha1", "old-sha1");
  seed(home, dir ~ newer ~ ".sha1", "new-sha1");
  // 注意：`alias` 是 D 关键字，变量名用 diffAlias
  auto diffAlias = "/portal-4.20.13_4.20.14-SNAPSHOT-linux-amd64.tar.gz.diff";

  HTTPStatusException err;
  auto head = exchange(config, "/native" ~ dir ~ diffAlias, HTTPMethod.HEAD, err);
  assert(err is null);
  assert(head.res.statusCode == HTTPStatus.ok);
  assert(head.res.headers["latest"] == newer[1 .. $]);
  assert(head.res.headers["Last-Modified"].endsWith("GMT"), head.res.headers["Last-Modified"]);

  auto get = exchange(config, "/native" ~ dir ~ diffAlias, HTTPMethod.GET, err);
  assert(err is null && get.res.statusCode == HTTPStatus.found);
  assert(get.res.headers["Location"] == "/native" ~ dir ~ newer);

  // `.sha1` 别名走同一规则
  auto sha1 = exchange(config, "/native" ~ dir ~ diffAlias ~ ".sha1", HTTPMethod.GET, err);
  assert(err is null && sha1.res.statusCode == HTTPStatus.found);
  assert(sha1.res.headers["Location"] == "/native" ~ dir ~ newer ~ ".sha1");

  // 发行包（无时间戳候选）不触发别名，直接发文件
  auto dist = exchange(config, "/native" ~ dir ~ "/portal-4.20.14-SNAPSHOT-linux-amd64.tar.gz",
      HTTPMethod.GET, err);
  assert(err is null && dist.res.statusCode == HTTPStatus.ok && dist.body == "dist");

  // 别名目标不存在（同目录没有任何时间戳候选）时按普通文件走 404，而不是 302 到空路径
  auto noCandidate = exchange(config, dir ~ "/portal-4.20.13_4.20.99-SNAPSHOT-linux-amd64.tar.gz.diff",
      HTTPMethod.GET, err);
  assert(err !is null && err.status == HTTPStatus.notFound);

  // 版本目录本身（尾斜杠）仍是目录列表，不会被「目录名含 -SNAPSHOT」的别名解析劫持
  auto dirList = exchange(config, "/native" ~ dir ~ "/", HTTPMethod.GET, err);
  assert(err is null && dirList.res.statusCode == HTTPStatus.ok);
  assert(dirList.body.canFind("portal-4.20.14-SNAPSHOT-linux-amd64.tar.gz"), dirList.body);
  assert(dirList.body.canFind(newer[1 .. $]), dirList.body);
}
