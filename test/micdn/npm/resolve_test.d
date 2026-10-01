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

module micdn.npm.resolve_test;
/// 开发版上游（`<npm><dev>`）：版本规格判定、上游选择与 resolve 取包。

import std.file;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.uuid : randomUUID;

import micdn.config : parse;
import micdn.model;
import micdn.npm;

/// 远端指向必然连不上的本机端口：这些用例只验证「命中本地缓存」与「选了哪些上游」，不访问网络。
private immutable string deadRemote = "http://127.0.0.1:1";

private string tempHome(string tag) {
  auto home = buildPath(tempDir, "micdn_npm_resolve_" ~ tag ~ "_" ~ randomUUID().toString);
  mkdirRecurse(home);
  return home;
}

/// 按 `{base}/{scope|_}/{name}/{version}/{name}-{version}.tgz` 写占位 tgz（`fetch` 只看存在与否）。
private string putTarball(string base, string scopePart, string namePart, string ver) {
  auto scopeDir = (scopePart.length > 0 && scopePart != "_") ? scopePart : "_";
  auto path = buildPath(base, scopeDir, namePart, ver, namePart ~ "-" ~ ver ~ ".tgz");
  mkdirRecurse(dirName(path));
  write(path, "tap");
  return path;
}

/// 在 packument 路径 `{base}/@scope/{name}`（无 scope 为 `{base}/{name}`）写元数据。
private string putPackument(string base, string scopePart, string namePart, string body) {
  auto path = (scopePart.length > 0 && scopePart != "_")
    ? buildPath(base, "@" ~ scopePart, namePart) : buildPath(base, namePart);
  mkdirRecurse(dirName(path));
  write(path, body);
  return path;
}

/// 共用仓库 + 可选开发版上游（远端都是 deadRemote，避免用例访问真实 registry）。
private MicdnConfig devConfig(string home, string npmBase, bool withDev = true) {
  auto dev = withDev ? `<dev remote="` ~ deadRemote ~ `"/>` : "";
  return parse(home, `<?xml version="1.0"?><micdn><npm base="` ~ npmBase ~ `">
  <remote url="` ~ deadRemote ~ `"/>
  ` ~ dev ~ `
</npm></micdn>`);
}

@("npm version specs: concrete version, dist-tag or dev channel")
unittest {
  assert(isConcreteVersion("1.2.3"));
  assert(isConcreteVersion("0.0.3-dev.2"));
  assert(isConcreteVersion("v1.2.3"));
  assert(!isConcreteVersion("dev"));
  assert(!isConcreteVersion("latest"));
  assert(!isConcreteVersion(""));

  assert(packageUri("xurp", "manual") == "/@xurp/manual");
  assert(packageUri("_", "left-pad") == "/left-pad");

  // 只有开发标识（dev/snapshot/…）的预发布版才算开发版
  assert(isDevVersionSpec("0.0.3-dev.2"), "development prerelease");
  assert(isDevVersionSpec("0.0.3-DEV.2"), "development ids are case-insensitive");
  assert(isDevVersionSpec("1.0-SNAPSHOT.1"));
  assert(isDevVersionSpec("dev"));
  assert(isDevVersionSpec("NEXT"), "channel tags are case-insensitive");
  // 正式 registry 上的预发布版（react 的 rc 之类）不是「我们的开发版」：仍走正式版上游
  assert(!isDevVersionSpec("1.2.0-rc.1"));
  assert(!isDevVersionSpec("19.0.0-beta.2"));
  assert(!isDevVersionSpec("2.0.0-20240101"));
  assert(!isDevVersionSpec("1.2.3"));
  assert(!isDevVersionSpec("latest"));
  assert(!isDevVersionSpec(""));
}

@("upstreams are picked by version: dev specs never fall back to the release remotes")
unittest {
  auto home = tempHome("upstreams");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto npmBase = buildPath(home, "npm");
  // 两个上游用不同地址，才能看出「选了哪一个」
  auto release = "file://" ~ buildPath(home, "up-release");
  auto dev = "file://" ~ buildPath(home, "up-dev");
  auto repo = NpmRepo.build(parse(home, `<?xml version="1.0"?><micdn><npm base="` ~ npmBase ~ `">
  <remote url="` ~ release ~ `"/>
  <dev remote="` ~ dev ~ `"/>
</npm></micdn>`));

  assert(repo.remotes == [release], "正式版上游来自 <npm><remote>");
  assert(repo.devRemote == dev, "开发版上游来自 <npm><dev remote=...>");
  assert(repo.upstreamsFor("1.2.3") == [release]);
  assert(repo.upstreamsFor("latest") == [release]);
  assert(repo.upstreamsFor("0.0.4-dev.2") == [dev], "具体开发版版本走 dev 上游");
  assert(repo.upstreamsFor("dev") == [dev]);
  assert(repo.upstreamsFor("1.2.0-rc.1") == [release],
      "预发布标识不是开发标识时走正式版上游");
  // packument 交付要把两个上游都取回来（URL 不带版本，判定不了来源）
  assert(repo.allUpstreams() == [release, dev]);

  // 未配置 <dev><remote>：开发版上游为空 = 不代理，只认本地
  auto noDev = NpmRepo.build(devConfig(home, npmBase, false));
  assert(noDev.devRemote.length == 0);
  assert(noDev.upstreamsFor("0.0.4-dev.2").length == 0);
  assert(noDev.upstreamsFor("1.2.3") == [deadRemote], "正式版仍走 <npm><remote>");
  assert(noDev.allUpstreams() == [deadRemote], "没配 <dev> 时只有一个上游");

  // 两个上游写成同一地址：去重
  auto same = NpmRepo.build(parse(home, `<?xml version="1.0"?><micdn><npm base="` ~ npmBase ~ `">
  <remote url="` ~ release ~ `"/>
  <dev remote="` ~ release ~ `"/>
</npm></micdn>`));
  assert(same.allUpstreams() == [release]);
}

@("dev and release versions share one local repo under <npm base>")
unittest {
  auto home = tempHome("shared");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto npmBase = buildPath(home, "npm");
  auto config = devConfig(home, npmBase);

  // 同一个 base 目录树：开发版与正式版按版本目录区分，互不干扰
  auto devTgz = putTarball(npmBase, "xurp", "manual", "0.0.4-dev.2");
  auto releaseTgz = putTarball(npmBase, "xurp", "manual", "0.0.4");
  assert(fetchNpmTarball(config, "xurp", "manual", "0.0.4-dev.2") == devTgz);
  assert(fetchNpmTarball(config, "xurp", "manual", "0.0.4") == releaseTgz);
  assert(fetchNpmTarball(config, "xurp", "manual", "9.9.9-dev.1") is null, "本地没有且不代理时返回 null");
}

@("dev dist-tags resolve to a concrete version through the packument")
unittest {
  auto home = tempHome("tag");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto npmBase = buildPath(home, "npm");
  auto config = devConfig(home, npmBase);

  putPackument(npmBase, "xurp", "manual",
      `{"name":"@xurp/manual","dist-tags":{"dev":"0.0.4-dev.2","latest":"0.0.4"}}`);
  auto devTgz = putTarball(npmBase, "xurp", "manual", "0.0.4-dev.2");
  auto releaseTgz = putTarball(npmBase, "xurp", "manual", "0.0.4");
  assert(fetchNpmTarball(config, "xurp", "manual", "dev") == devTgz);
  assert(fetchNpmTarball(config, "xurp", "manual", "latest") == releaseTgz);

  // packument 里没有的 tag：本地解析不出，上游又连不上 → null
  assert(fetchNpmTarball(config, "xurp", "manual", "canary") is null);
}

@("a dev version installed locally is served without any dev remote")
unittest {
  auto home = tempHome("localonly");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto npmBase = buildPath(home, "npm");
  auto config = devConfig(home, npmBase, false);

  // `micdn install` 装入的开发版（packument + tgz 都在 {base} 下），不配 <dev> 也能取证
  putPackument(npmBase, "xurp", "manual",
      `{"name":"@xurp/manual","dist-tags":{"dev":"0.0.4-dev.2"}}`);
  auto devTgz = putTarball(npmBase, "xurp", "manual", "0.0.4-dev.2");
  assert(fetchNpmTarball(config, "xurp", "manual", "dev") == devTgz);
  assert(fetchNpmTarball(config, "xurp", "manual", "0.0.4-dev.2") == devTgz);
}

@("a packument cached from one registry is re-fetched when the wanted tag is missing")
unittest {
  auto home = tempHome("flip");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto npmBase = buildPath(home, "npm");
  auto releaseUpstream = buildPath(home, "up-release");
  auto devUpstream = buildPath(home, "up-dev");
  // 两个上游各自只有自己那份 packument；用 file:// 当 registry，免起 HTTP 服务
  putPackument(releaseUpstream, "xurp", "manual",
      `{"name":"@xurp/manual","dist-tags":{"latest":"0.0.4"},`
      ~ `"versions":{"0.0.4":{"dist":{"tarball":"https://rel/@xurp/manual/-/manual-0.0.4.tgz"}}}}`);
  putPackument(devUpstream, "xurp", "manual", `{"name":"@xurp/manual","dist-tags":{"dev":"0.0.5-dev.1"},`
      ~ `"versions":{"0.0.5-dev.1":{"dist":{"tarball":"https://dev/@xurp/manual/-/manual-0.0.5-dev.1.tgz"}}}}`);
  auto config = parse(home, `<?xml version="1.0"?><micdn><npm base="` ~ npmBase ~ `">
  <remote url="file://` ~ releaseUpstream ~ `"/>
  <dev remote="file://` ~ devUpstream ~ `"/>
</npm></micdn>`);
  auto repo = NpmRepo.build(config);

  // 模拟「开发版先落盘」：本地 packument 只有 dev 版本，正式版 tag 得回正式版上游取
  putPackument(npmBase, "xurp", "manual", `{"name":"@xurp/manual","dist-tags":{"dev":"0.0.5-dev.1"},`
      ~ `"versions":{"0.0.5-dev.1":{"dist":{"tarball":"https://dev/@xurp/manual/-/manual-0.0.5-dev.1.tgz"}}}}`);
  assert(repo.resolveVersion("xurp", "manual", "latest") == "0.0.4");
  // 并入式落盘：正式版上游的 latest 与本地已有的 dev 同时保留在同一份 packument 里
  auto doc = parseJSON(readText(buildPath(npmBase, "@xurp/manual")));
  assert(doc["dist-tags"]["latest"].str == "0.0.4", "正式版 tag 落盘");
  assert(doc["dist-tags"]["dev"].str == "0.0.5-dev.1", "本地 dev tag 不被上游文档覆盖");
  // 本地已有该 tag 时不再访问上游
  assert(repo.resolveVersion("xurp", "manual", "dev") == "0.0.5-dev.1");

  // 反向：本地只剩正式版时，dev tag 回开发版上游取，latest 同样保留
  putPackument(npmBase, "xurp", "manual", `{"name":"@xurp/manual","dist-tags":{"latest":"0.0.4"},`
      ~ `"versions":{"0.0.4":{"dist":{"tarball":"https://rel/@xurp/manual/-/manual-0.0.4.tgz"}}}}`);
  assert(repo.resolveVersion("xurp", "manual", "dev") == "0.0.5-dev.1");
  auto back = parseJSON(readText(buildPath(npmBase, "@xurp/manual")));
  assert(back["dist-tags"]["latest"].str == "0.0.4", "取 dev 不得抹掉 latest");
  assert(back["dist-tags"]["dev"].str == "0.0.5-dev.1");

  // 谁都没有的 tag 返回 null
  assert(repo.resolveVersion("xurp", "manual", "canary") is null);
}

@("the resolved tarball comes from the same upstream that resolved the tag")
unittest {
  auto home = tempHome("tag-source");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto npmBase = buildPath(home, "npm");
  auto releaseUpstream = buildPath(home, "up-release");
  auto devUpstream = buildPath(home, "up-dev");
  mkdirRecurse(releaseUpstream);
  // dev 上游只有 tgz（file:// 上游无法让 packument 文件与 tarball 目录同名共存，故 packument 放本地）
  auto upstreamTgz = buildPath(devUpstream, "manual/-/manual-1.0.0-next.1.tgz");
  mkdirRecurse(dirName(upstreamTgz));
  write(upstreamTgz, "tap");
  // 本地 packument：`next` tag 指向 1.0.0-next.1（标识 next 不在 developmentIds 里）
  putPackument(npmBase, "_", "manual", `{"dist-tags":{"next":"1.0.0-next.1"}}`);

  auto config = parse(home, `<?xml version="1.0"?><micdn><npm base="` ~ npmBase ~ `">
  <remote url="file://` ~ releaseUpstream ~ `"/>
  <dev remote="file://` ~ devUpstream ~ `"/>
</npm></micdn>`);

  // `next` 是通道 tag → 走 dev 上游；解析出的具体版本照旧从 dev 上游取 tgz（不因标识不同回到正式版）
  auto fetched = fetchNpmTarball(config, "_", "manual", "next");
  assert(fetched == buildPath(npmBase, "_", "manual", "1.0.0-next.1",
      "manual-1.0.0-next.1.tgz"), fetched is null ? "null" : fetched);
  assert(readText(fetched) == "tap");
}

@("fetchPackument merges the release and dev upstream documents into one file")
unittest {
  auto home = tempHome("merge-fetch");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto npmBase = buildPath(home, "npm");
  auto releaseUpstream = buildPath(home, "up-release");
  auto devUpstream = buildPath(home, "up-dev");
  auto releaseUrl = "https://mirror.example.com/@xurp/manual/-/manual-0.0.4.tgz";
  auto devUrl = "https://dev.example.com/@xurp/manual/-/manual-0.0.5-dev.1.tgz";
  putPackument(releaseUpstream, "xurp", "manual",
      `{"name":"@xurp/manual","dist-tags":{"latest":"0.0.4"},`
      ~ `"versions":{"0.0.4":{"dist":{"tarball":"` ~ releaseUrl ~ `"}}}}`);
  putPackument(devUpstream, "xurp", "manual",
      `{"name":"@xurp/manual","dist-tags":{"dev":"0.0.5-dev.1"},`
      ~ `"versions":{"0.0.5-dev.1":{"dist":{"tarball":"` ~ devUrl ~ `"}}}}`);
  auto repo = NpmRepo.build(parse(home, `<?xml version="1.0"?><micdn><npm base="` ~ npmBase ~ `">
  <remote url="file://` ~ releaseUpstream ~ `"/>
  <dev remote="file://` ~ devUpstream ~ `"/>
</npm></micdn>`));

  // 交付路径不带版本：两个上游的文档都要并入同一份，客户端才同时看得见 latest 与 dev
  assert(repo.fetchPackument("/@xurp/manual"));
  auto doc = parseJSON(readText(buildPath(npmBase, "@xurp/manual")));
  assert(doc["dist-tags"]["latest"].str == "0.0.4");
  assert(doc["dist-tags"]["dev"].str == "0.0.5-dev.1");
  assert(doc["versions"]["0.0.4"]["dist"]["tarball"].str == releaseUrl);
  assert(doc["versions"]["0.0.5-dev.1"]["dist"]["tarball"].str == devUrl);
}
