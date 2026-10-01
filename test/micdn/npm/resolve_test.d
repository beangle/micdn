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

  assert(isDevVersionSpec("0.0.3-dev.2"), "semver prerelease");
  assert(isDevVersionSpec("1.2.0-rc.1"));
  assert(isDevVersionSpec("dev"));
  assert(isDevVersionSpec("NEXT"), "channel tags are case-insensitive");
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
  auto config = devConfig(home, npmBase);
  auto repo = NpmRepo.build(config);

  assert(repo.remotes == [deadRemote], "正式版上游来自 <npm><remote>");
  assert(repo.devRemote == deadRemote, "开发版上游来自 <npm><dev remote=...>");
  assert(repo.upstreamsFor("1.2.3") == [deadRemote]);
  assert(repo.upstreamsFor("latest") == [deadRemote]);
  assert(repo.upstreamsFor("0.0.4-dev.2") == [deadRemote], "具体开发版版本也走 dev 上游");
  assert(repo.upstreamsFor("dev") == [deadRemote]);

  // 未配置 <dev><remote>：开发版上游为空 = 不代理，只认本地
  auto noDev = NpmRepo.build(devConfig(home, npmBase, false));
  assert(noDev.devRemote.length == 0);
  assert(noDev.upstreamsFor("0.0.4-dev.2").length == 0);
  assert(noDev.upstreamsFor("1.2.3") == [deadRemote], "正式版仍走 <npm><remote>");
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
  putPackument(releaseUpstream, "xurp", "manual", `{"dist-tags":{"latest":"0.0.4"}}`);
  putPackument(devUpstream, "xurp", "manual", `{"dist-tags":{"dev":"0.0.5-dev.1"}}`);
  auto config = parse(home, `<?xml version="1.0"?><micdn><npm base="` ~ npmBase ~ `">
  <remote url="file://` ~ releaseUpstream ~ `"/>
  <dev remote="file://` ~ devUpstream ~ `"/>
</npm></micdn>`);
  auto repo = NpmRepo.build(config);

  // 模拟「开发版先落盘」：本地 packument 只有 dev tag，正式版 tag 得回正式版上游重取
  putPackument(npmBase, "xurp", "manual", `{"dist-tags":{"dev":"0.0.5-dev.1"}}`);
  assert(repo.resolveVersion("xurp", "manual", "latest") == "0.0.4");
  // 此时本地被换成了正式版那份，dev tag 同样能回开发版上游重取
  assert(repo.resolveVersion("xurp", "manual", "dev") == "0.0.5-dev.1");
  // 本地已有该 tag 时不再访问上游（两个上游都只剩对方那份也能命中）
  assert(repo.resolveVersion("xurp", "manual", "dev") == "0.0.5-dev.1");
  // 谁都没有的 tag 返回 null
  assert(repo.resolveVersion("xurp", "manual", "canary") is null);
}
