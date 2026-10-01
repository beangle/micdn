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

module test.micdn.maven.snapshot_test;

import std.algorithm : canFind;
import std.digest : toHexString;
import std.digest.sha : sha1Of;
import std.exception : assertThrown, collectException;
import std.file;
import std.path : buildPath;
import std.string : endsWith, replace, toUpper;
import std.uuid : randomUUID;
import std.zip : ArchiveMember, ZipArchive;

import vibe.http.common : HTTPMethod, HTTPStatus, HTTPStatusException;
import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse, HTTPServerResponse,
    TestHTTPResponseMode;
import vibe.inet.message : InetHeaderMap;
import vibe.inet.url : URL;
import vibe.stream.memory : createMemoryOutputStream;

import micdn.config : parseFile;
import micdn.maven.snapshot;
import micdn.maven.web : MavenService, SnapshotService;

// ---- 造工件 ----

private string tempHome() {
  auto home = buildPath(tempDir, "micdn_snapshot_" ~ randomUUID().toString);
  mkdirRecurse(home);
  return home;
}

/// `mvn deploy` 用时间戳替换 `-SNAPSHOT` 后再拼文件名。
private string stampVersion(string ver) {
  return ver.endsWith("-SNAPSHOT") ? ver[0 .. $ - "-SNAPSHOT".length] : ver;
}

/// 写一个含若干条目的 zip（条目顺序由关联数组决定，正好顺带验证坐标读取不依赖顺序）。
private string writeZip(string path, string[string] entries) {
  auto z = new ZipArchive();
  foreach (entry, content; entries) {
    auto m = new ArchiveMember();
    m.name = entry;
    m.expandedData(cast(ubyte[]) content);
    z.addMember(m);
  }
  std.file.write(path, z.build());
  return path;
}

private string writeZip(string path, string entry, string content) {
  return writeZip(path, [entry: content]);
}

/// pom.properties 的正文（字段顺序与真实 mvn 产物一致：artifactId 在前）。
private string properties(string group, string artifact, string ver) {
  return "artifactId=" ~ artifact ~ "\ngroupId=" ~ group ~ "\nversion=" ~ ver ~ "\n";
}

/// 带 `META-INF/maven/{group}/{artifact}/pom.properties` 的 jar。
private string makeJar(string dir, string group, string artifact, string ver, string build, string classifier = "") {
  mkdirRecurse(dir);
  auto suffix = classifier.length > 0 ? "-" ~ classifier : "";
  auto file = buildPath(dir, artifact ~ "-" ~ stampVersion(ver) ~ "-" ~ build ~ suffix ~ ".jar");
  return writeZip(file, "META-INF/maven/" ~ group.replace(".", "/") ~ "/" ~ artifact ~ "/pom.properties",
      properties(group, artifact, ver));
}

/// 带 `WEB-INF/classes/META-INF/maven/.../pom.properties` 的 war。
private string makeWar(string dir, string group, string artifact, string ver, string build) {
  mkdirRecurse(dir);
  auto file = buildPath(dir, artifact ~ "-" ~ stampVersion(ver) ~ "-" ~ build ~ ".war");
  return writeZip(file, "WEB-INF/classes/META-INF/maven/" ~ group.replace(".", "/") ~ "/" ~ artifact
      ~ "/pom.properties", properties(group, artifact, ver));
}

/// 只有 `MANIFEST.MF`（Implementation-* 属性）的 jar。
private string makeManifestJar(string dir, string group, string artifact, string ver, string build) {
  mkdirRecurse(dir);
  auto file = buildPath(dir, artifact ~ "-" ~ stampVersion(ver) ~ "-" ~ build ~ ".jar");
  auto manifest = "Manifest-Version: 1.0\n"
    ~ "Implementation-Vendor-Id: " ~ group ~ "\n"
    ~ "Implementation-Title: " ~ artifact ~ "\n"
    ~ "Implementation-Version: " ~ ver ~ "\n\n";
  return writeZip(file, "META-INF/MANIFEST.MF", manifest);
}

private string makePom(string dir, string group, string artifact, string ver, string build) {
  mkdirRecurse(dir);
  auto file = buildPath(dir, artifact ~ "-" ~ stampVersion(ver) ~ "-" ~ build ~ ".pom");
  std.file.write(file, `<?xml version="1.0"?>
<project><modelVersion>4.0.0</modelVersion>
  <groupId>` ~ group ~ `</groupId>
  <artifactId>` ~ artifact ~ `</artifactId>
  <version>` ~ ver ~ `</version>
</project>
`);
  return file;
}

/// 写一份含 `<snapshot base>` 的配置，返回配置文件路径。
private string writeConfig(string home) {
  auto xmlPath = buildPath(home, "micdn.xml");
  std.file.write(xmlPath, `<?xml version="1.0"?><micdn listen="127.0.0.1:8888">
  <maven base="` ~ buildPath(home, "maven") ~ `">
    <snapshot base="` ~ buildPath(home, "snapshots") ~ `"/>
  </maven>
</micdn>`);
  return xmlPath;
}

/// 一次 handler 调用的结果：正文 + 响应（供断言状态码/响应头）。
private struct Exchange {
  string body;
  HTTPServerResponse res;
}

/// 调用 handler（Host 固定 `cdn.example.com`），捕获 HTTPStatusException；handler 正常返回时 error 为 null。
private Exchange exchange(T)(T service, string url, HTTPMethod method, out HTTPStatusException error,
    string[string] extraHeaders = null) {
  InetHeaderMap headers;
  headers["Host"] = "cdn.example.com";
  foreach (k, v; extraHeaders)
    headers[k] = v;
  auto output = createMemoryOutputStream();
  auto req = createTestHTTPServerRequest(URL("http://cdn.example.com" ~ url), method, headers, null);
  auto res = createTestHTTPServerResponse(output, null, TestHTTPResponseMode.bodyOnly);
  error = collectException!HTTPStatusException(service.service(req, res));
  return Exchange(cast(string) output.data, res);
}

// ---- 文件名解析 ----

@("parse snapshot file name accepts only mvn-deployed timestamped names")
unittest {
  SnapshotFile f;
  assert(parseSnapshotName("commons-5.0.0-20250803.132600-31.jar", "commons", "5.0.0-SNAPSHOT", f));
  assert(f.timestamp == "20250803.132600");
  assert(f.build == 31);
  assert(f.classifier == "");
  assert(f.ext == "jar");

  assert(parseSnapshotName("commons-5.0.0-20250803.132600-31-sources.jar", "commons", "5.0.0-SNAPSHOT", f));
  assert(f.classifier == "sources");
  assert(f.ext == "jar");
  assert(f.build == 31);

  // 裸 -SNAPSHOT 名（未经 mvn deploy）不接受
  assert(!parseSnapshotName("commons-5.0.0-SNAPSHOT.jar", "commons", "5.0.0-SNAPSHOT", f));
  // 校验文件后缀带点，不按工件解析
  assert(!parseSnapshotName("commons-5.0.0-20250803.132600-31.jar.sha1", "commons", "5.0.0-SNAPSHOT", f));
  // 时间戳不合法 / build 非数字
  assert(!parseSnapshotName("commons-5.0.0-2025080.132600-31.jar", "commons", "5.0.0-SNAPSHOT", f));
  assert(!parseSnapshotName("commons-5.0.0-20250803.132600-x.jar", "commons", "5.0.0-SNAPSHOT", f));
  // 别家 artifact
  assert(!parseSnapshotName("other-5.0.0-20250803.132600-31.jar", "commons", "5.0.0-SNAPSHOT", f));
}

// ---- 坐标解析 ----

@("read coordinates from pom.properties, manifest and pom")
unittest {
  auto home = tempHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);

  auto jar = makeJar(buildPath(home, "in"), "org.beangle.commons", "beangle-commons",
      "5.0.0-SNAPSHOT", "20250803.132600-31");
  auto c1 = readSnapshotCoordinates(jar);
  assert(c1.group == "org.beangle.commons" && c1.artifact == "beangle-commons" && c1.ver == "5.0.0-SNAPSHOT");

  auto war = makeWar(buildPath(home, "in"), "org.beangle.ems", "beangle-ems-app",
      "1.2.3-SNAPSHOT", "20250803.132600-1");
  auto c2 = readSnapshotCoordinates(war);
  assert(c2.group == "org.beangle.ems" && c2.artifact == "beangle-ems-app" && c2.ver == "1.2.3-SNAPSHOT");

  auto mjar = makeManifestJar(buildPath(home, "in"), "org.beangle", "legacy", "0.1.0-SNAPSHOT",
      "20250803.132600-3");
  auto c3 = readSnapshotCoordinates(mjar);
  assert(c3.group == "org.beangle" && c3.artifact == "legacy" && c3.ver == "0.1.0-SNAPSHOT");

  auto pom = makePom(buildPath(home, "in"), "org.beangle.foo", "foo", "2.0.0-SNAPSHOT", "20250803.132600-5");
  auto c4 = readSnapshotCoordinates(pom);
  assert(c4.group == "org.beangle.foo" && c4.artifact == "foo" && c4.ver == "2.0.0-SNAPSHOT");

  // 无坐标信息 → 报错
  auto bad = buildPath(home, "in", "empty-1.0.0-20250803.132600-1.jar");
  writeZip(bad, "readme.txt", "x");
  assertThrown(readSnapshotCoordinates(bad));
}

@("pom.properties wins over MANIFEST.MF and pom.xml inherits from <parent>")
unittest {
  auto home = tempHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);

  // 两个条目同时存在时，pom.properties 是权威坐标（MANIFEST 的 Implementation-* 被忽略）
  mkdirRecurse(buildPath(home, "in"));
  auto jar = buildPath(home, "in", "mixed-2.0.0-20250803.132600-7.jar");
  writeZip(jar, [
    "META-INF/maven/org.beangle/mixed/pom.properties": properties("org.beangle", "mixed", "2.0.0-SNAPSHOT"),
    "META-INF/MANIFEST.MF": "Manifest-Version: 1.0\n"
      ~ "Implementation-Vendor-Id: org.other\n"
      ~ "Implementation-Title: other\n"
      ~ "Implementation-Version: 9.9.9\n\n"
  ]);
  auto coords = readSnapshotCoordinates(jar);
  assert(coords.group == "org.beangle" && coords.artifact == "mixed" && coords.ver == "2.0.0-SNAPSHOT");

  // pom 缺 groupId/version 时继承 <parent>
  auto pom = buildPath(home, "in", "child-1.0.0-20250803.132600-1.pom");
  std.file.write(pom, `<?xml version="1.0"?>
<project><modelVersion>4.0.0</modelVersion>
  <parent><groupId>org.beangle.parent</groupId><version>1.0.0-SNAPSHOT</version></parent>
  <artifactId>child</artifactId>
</project>
`);
  auto child = readSnapshotCoordinates(pom);
  assert(child.group == "org.beangle.parent" && child.artifact == "child" && child.ver == "1.0.0-SNAPSHOT");
}

// ---- 安装 ----

@("installSnapshot lays out files, writes sha1 and metadata")
unittest {
  auto home = tempHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);

  auto repo = new SnapshotRepo(buildPath(home, "snapshots"));
  auto jar = makeJar(buildPath(home, "in"), "org.beangle.commons", "beangle-commons",
      "5.0.0-SNAPSHOT", "20250803.132600-31");
  auto result = installSnapshot(repo, jar);

  assert(result.uri == "/org/beangle/commons/beangle-commons/5.0.0-SNAPSHOT/"
      ~ "beangle-commons-5.0.0-20250803.132600-31.jar");
  assert(result.file == buildPath(home, "snapshots") ~ result.uri);
  assert(exists(result.file));
  assert(exists(result.file ~ ".sha1"));
  assert(toUpper(readText(result.file ~ ".sha1")) == toHexString(sha1Of(cast(ubyte[]) read(result.file))));

  auto metadata = readText(result.metadata);
  assert(metadata.canFind("<groupId>org.beangle.commons</groupId>"));
  assert(metadata.canFind("<artifactId>beangle-commons</artifactId>"));
  assert(metadata.canFind("<version>5.0.0-SNAPSHOT</version>"));
  assert(metadata.canFind("<timestamp>20250803.132600</timestamp>"));
  assert(metadata.canFind("<buildNumber>31</buildNumber>"));
  assert(metadata.canFind("<lastUpdated>20250803132600</lastUpdated>"));
  assert(metadata.canFind("<extension>jar</extension>"));
  assert(metadata.canFind("<value>5.0.0-20250803.132600-31</value>"));
  assert(exists(result.metadata ~ ".sha1"));

  // 裸 -SNAPSHOT 名不接受
  auto bare = buildPath(home, "in", "beangle-commons-5.0.0-SNAPSHOT.jar");
  copy(jar, bare);
  assertThrown(installSnapshot(repo, bare));

  // 非 SNAPSHOT 版本不接受
  auto release = makeJar(buildPath(home, "in"), "org.beangle.commons", "beangle-commons", "5.0.0",
      "20250803.132600-31");
  assertThrown(installSnapshot(repo, release));
}

@("installSnapshot is idempotent and metadata lists every extension")
unittest {
  auto home = tempHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);

  auto repo = new SnapshotRepo(buildPath(home, "snapshots"));
  auto inDir = buildPath(home, "in");
  auto jar = makeJar(inDir, "org.beangle", "tool", "1.0.0-SNAPSHOT", "20250803.132600-4");
  auto pom = makePom(inDir, "org.beangle", "tool", "1.0.0-SNAPSHOT", "20250803.132600-4");
  installSnapshot(repo, jar);
  auto result = installSnapshot(repo, pom);

  auto metadata = readText(result.metadata);
  assert(metadata.canFind("<extension>jar</extension>"));
  assert(metadata.canFind("<extension>pom</extension>"));
  assert(metadata.canFind("<value>1.0.0-20250803.132600-4</value>"));

  // 重复 install 同一构件：元数据与 sha1 都不变（元数据完全由目录内容推导，无增量状态）
  auto sha1Before = readText(result.metadata ~ ".sha1");
  installSnapshot(repo, jar);
  assert(readText(result.metadata) == metadata);
  assert(readText(result.metadata ~ ".sha1") == sha1Before);

  auto vdir = "/org/beangle/tool/1.0.0-SNAPSHOT";
  assert(repo.latestAlias(vdir ~ "/tool-1.0.0-SNAPSHOT.pom") == vdir ~ "/tool-1.0.0-20250803.132600-4.pom");
  // 未装入的 classifier 不解析成别名
  assert(repo.latestAlias(vdir ~ "/tool-1.0.0-SNAPSHOT-javadoc.jar") is null);
}

@("latest alias resolves to the newest build and honours classifiers")
unittest {
  auto home = tempHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);

  auto repo = new SnapshotRepo(buildPath(home, "snapshots"));
  auto inDir = buildPath(home, "in");
  installSnapshot(repo, makeJar(inDir, "org.beangle.commons", "beangle-commons", "5.0.0-SNAPSHOT",
      "20250802.120000-1"));
  installSnapshot(repo, makeJar(inDir, "org.beangle.commons", "beangle-commons", "5.0.0-SNAPSHOT",
      "20250803.132600-2"));
  installSnapshot(repo, makeJar(inDir, "org.beangle.commons", "beangle-commons", "5.0.0-SNAPSHOT",
      "20250803.132600-2", "sources"));

  auto vdir = "/org/beangle/commons/beangle-commons/5.0.0-SNAPSHOT";
  assert(repo.latestAlias(vdir ~ "/beangle-commons-5.0.0-SNAPSHOT.jar")
      == vdir ~ "/beangle-commons-5.0.0-20250803.132600-2.jar");
  assert(repo.latestAlias(vdir ~ "/beangle-commons-5.0.0-SNAPSHOT.jar.sha1")
      == vdir ~ "/beangle-commons-5.0.0-20250803.132600-2.jar.sha1");
  assert(repo.latestAlias(vdir ~ "/beangle-commons-5.0.0-SNAPSHOT-sources.jar")
      == vdir ~ "/beangle-commons-5.0.0-20250803.132600-2-sources.jar");
  // .jar 请求不会落到 .jar.sha1，反之亦然
  assert(repo.latestAlias(vdir ~ "/beangle-commons-5.0.0-SNAPSHOT.pom") is null);
  // 不带 -SNAPSHOT 的请求不解析别名
  assert(repo.latestAlias(vdir ~ "/beangle-commons-5.0.0.jar") is null);
  // 目录不存在
  assert(repo.latestAlias("/org/beangle/none/1.0-SNAPSHOT/none-1.0-SNAPSHOT.jar") is null);

  auto metadata = readText(buildPath(home, "snapshots") ~ vdir ~ "/maven-metadata.xml");
  assert(metadata.canFind("<buildNumber>2</buildNumber>"));
  assert(metadata.canFind("<extension>jar</extension>"));
  assert(metadata.canFind("<classifier>sources</classifier>"));
}

// ---- HTTP 服务 ----

@("snapshot service redirects aliases and serves timestamped files")
unittest {
  auto home = tempHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);

  auto xmlPath = writeConfig(home);
  installSnapshot(SnapshotRepo.build(parseFile(xmlPath)),
      makeJar(buildPath(home, "in"), "org.beangle.commons", "beangle-commons",
          "5.0.0-SNAPSHOT", "20250803.132600-31"));
  auto service = new SnapshotService(parseFile(xmlPath));
  auto vdir = "/org/beangle/commons/beangle-commons/5.0.0-SNAPSHOT";
  auto timestamped = "beangle-commons-5.0.0-20250803.132600-31.jar";

  HTTPStatusException err;

  // GET 别名 → 302 到时间戳文件，携带 latest 头
  auto r = exchange(service, "/snapshot" ~ vdir ~ "/beangle-commons-5.0.0-SNAPSHOT.jar", HTTPMethod.GET, err);
  assert(err is null);
  assert(r.res.statusCode == HTTPStatus.found);
  assert(r.res.headers["latest"] == timestamped);
  assert(r.res.headers["Location"] == "/snapshot" ~ vdir ~ "/" ~ timestamped);

  // HEAD 别名 → 200 + latest 头（sashub 语义）
  auto h = exchange(service, "/snapshot" ~ vdir ~ "/beangle-commons-5.0.0-SNAPSHOT.jar", HTTPMethod.HEAD, err);
  assert(err is null);
  assert(h.res.statusCode == HTTPStatus.ok);
  assert(h.res.headers["latest"] == timestamped);

  // 时间戳文件 → 200 且内容一致
  auto f = exchange(service, "/snapshot" ~ vdir ~ "/" ~ timestamped, HTTPMethod.GET, err);
  assert(err is null);
  assert(f.body == cast(string) read(buildPath(home, "snapshots") ~ vdir ~ "/" ~ timestamped));

  // maven-metadata.xml → 200
  auto m = exchange(service, "/snapshot" ~ vdir ~ "/maven-metadata.xml", HTTPMethod.GET, err);
  assert(err is null);
  assert(m.body.canFind("<artifactId>beangle-commons</artifactId>"));

  // 别名指向不存在的时间戳文件（未被装入）→ 404
  exchange(service, "/snapshot" ~ vdir ~ "/beangle-commons-5.0.0-SNAPSHOT.pom", HTTPMethod.GET, err);
  assert(err !is null && err.status == HTTPStatus.notFound);
  // 缺失文件 → 404
  exchange(service, "/snapshot" ~ vdir ~ "/beangle-commons-5.0.0-20250803.132600-31.pom", HTTPMethod.GET, err);
  assert(err !is null && err.status == HTTPStatus.notFound);
}

@("snapshot service applies snapshot cache policies and rejects client state files")
unittest {
  auto home = tempHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);

  auto xmlPath = writeConfig(home);
  installSnapshot(SnapshotRepo.build(parseFile(xmlPath)),
      makeJar(buildPath(home, "in"), "org.beangle", "tool", "1.0.0-SNAPSHOT", "20250803.132600-4"));
  auto service = new SnapshotService(parseFile(xmlPath));
  auto vdir = "/org/beangle/tool/1.0.0-SNAPSHOT";
  auto jarUri = "/snapshot" ~ vdir ~ "/tool-1.0.0-20250803.132600-4.jar";

  HTTPStatusException err;

  // 元数据：每次回源校验（元数据随时变）
  auto meta = exchange(service, "/snapshot" ~ vdir ~ "/maven-metadata.xml", HTTPMethod.GET, err);
  assert(err is null);
  assert(meta.res.headers["Cache-Control"] == "public, no-cache");

  // 快照构件：路径含 SNAPSHOT，同一路径可能被覆盖重发
  auto jar = exchange(service, jarUri, HTTPMethod.GET, err);
  assert(err is null && jar.body.length > 0);
  assert(jar.res.headers["Cache-Control"] == "no-store");
  assert(toUpper(jar.res.headers["Etag"]).length > 0, "条件请求仍靠 ETag 校验");

  // 条件请求按 handleCacheFile 处理：命中 ETag 回 304、无正文
  auto notModified = exchange(service, jarUri, HTTPMethod.GET, err, ["If-None-Match": jar.res.headers["Etag"]]);
  assert(err is null);
  assert(notModified.res.statusCode == HTTPStatus.notModified);
  assert(notModified.body.length == 0);

  // maven 客户端写入的本地状态文件不作为构件提供
  foreach (name; ["resolver-status.properties", "tool-1.0.0-SNAPSHOT.jar.lastUpdated"]) {
    exchange(service, "/snapshot" ~ vdir ~ "/" ~ name, HTTPMethod.GET, err);
    assert(err !is null && err.status == HTTPStatus.notFound, name);
  }
}

@("maven service no longer serves any SNAPSHOT path")
unittest {
  auto home = tempHome();
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);

  auto xmlPath = writeConfig(home);
  auto service = new MavenService(parseFile(xmlPath));

  HTTPStatusException err;
  exchange(service, "/maven/org/beangle/commons/beangle-commons/5.0.0-SNAPSHOT/beangle-commons-5.0.0-SNAPSHOT.jar",
      HTTPMethod.GET, err);
  assert(err !is null && err.status == HTTPStatus.notFound);
  exchange(service, "/maven/org/beangle/commons/beangle-commons/5.0.0-SNAPSHOT/maven-metadata.xml",
      HTTPMethod.GET, err);
  assert(err !is null && err.status == HTTPStatus.notFound);
}
