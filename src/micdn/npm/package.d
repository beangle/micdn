/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.npm;
/// NPM 仓库本地缓存与从 registry 拉取 tgz。
///
/// 正式版与开发版（`<npm><dev remote="..."/>`）**共用** `/npm` 入口与 `<npm base>` 目录树：本地一份 packument
/// 同时承载两个通道的版本与 dist-tags，回源时按版本规格选上游。整体设计（含「为什么不能拆目录」）见
/// `docs/merged_repo.md`。

import std.algorithm;
import std.conv;
import std.exception;
import std.file;
import std.json : JSONType, parseJSON;
import std.path : baseName, dirName;
import std.string;
import std.typecons;
import std.uri;

import vibe.core.log;

import micdn.model;
import micdn.npm.packument : mergeUpstreamPackument, originPlaceholder, prereleaseChannels;
import micdn.routes : mountNpm;
import micdn.web.file;
import micdn.web : normalizeBasePath;

/** 解析 NPM 包规格 @scope/name@version 或 name@version，通过 ref 返回 (scopePart, namePart, versionPart)。
    scopePart 无 scope 时为 "_"。
*/
void parsePackageSpec(string packageSpec, ref string scopePart, ref string namePart,
    ref string versionPart) {
  scopePart = "_";
  namePart = null;
  versionPart = null;
  if (packageSpec.length == 0)
    return;
  size_t atVer = packageSpec.lastIndexOf('@');
  if (atVer == size_t.max || atVer == 0) {
    return;
  }
  versionPart = packageSpec[atVer + 1 .. $];
  string rest = packageSpec[0 .. atVer];
  if (rest.startsWith("@") && rest.length > 1) {
    auto slash = rest.indexOf("/");
    if (slash > 1) {
      scopePart = rest[1 .. slash];
      namePart = rest[slash + 1 .. $];
    } else {
      namePart = rest;
    }
  } else {
    namePart = rest;
  }
}

/// 解析 NPM tarball URI（{packageName}/-/{name}-{version}.tgz）为 (scopePart, namePart, versionPart)。
/// 成功时返回三元素元组，失败返回 null。
/// 例：@scope/pkg/-/pkg-1.0.0.tgz、lodash/-/lodash-4.17.21.tgz
Tuple!(string, string, string) parseTarballUri(string path) {
  auto slashDash = path.indexOf("/-/");
  if (slashDash < 0)
    return Tuple!(string, string, string)(null, null, null);
  string packageName = path[0 .. slashDash].stripLeft('/');
  string filename = path[slashDash + 3 .. $];
  if (!filename.endsWith(".tgz") || packageName.length == 0)
    return Tuple!(string, string, string)(null, null, null);

  string scopePart, namePart;
  if (packageName.startsWith("@") && packageName.length > 1) {
    auto slash = packageName.indexOf("/");
    if (slash < 0 || slash < 2)
      return Tuple!(string, string, string)(null, null, null);
    scopePart = packageName[1 .. slash];
    namePart = packageName[slash + 1 .. $];
  } else {
    scopePart = "_";
    namePart = packageName;
  }
  if (namePart.length == 0)
    return Tuple!(string, string, string)(null, null, null);

  string prefix = namePart ~ "-";
  if (!filename.startsWith(prefix) || filename.length <= prefix.length + 4)
    return Tuple!(string, string, string)(null, null, null);
  string versionPart = filename[prefix.length .. $ - 4]; // 去掉 .tgz
  return Tuple!(string, string, string)(scopePart, namePart, versionPart);
}

/** npm 仓库根：本地缓存与上游 registry 回源（正式版 `remotes` / 开发版 `devRemote`）。

    正式版与开发版**共用**同一 `base`：一个包只有一份 packument（`{base}/{pkg}`），承载两个通道的版本与
    dist-tags；回源按版本规格选上游（`upstreamsFor`），packument 交付路径则并入全部上游（`allUpstreams`）。
    整体设计见 `docs/merged_repo.md`。
*/
class NpmRepo {
  /// 本地缓存根目录（绝对路径）
  const string base;
  /// 正式版上游 registry 列表（按优先级）
  const string[] remotes;
  /// 开发版（dev/预发布）专用 registry（`<npm><dev remote="..."/>`）；空串表示开发版不代理、只认本地
  const string devRemote;

  this(const string base, const string[] remotes, const string devRemote = "") {
    enforce(base.length > 0, "repo base must not be empty");
    this.base = normalizeBasePath(base);
    this.remotes = remotes;
    this.devRemote = devRemote;
  }

  static NpmRepo build(MicdnConfig config) {
    mkdirRecurse(config.npm.base);
    return new NpmRepo(config.npm.base, config.npm.remotes, config.npm.devRemote);
  }

  /** 版本规格对应的上游列表（按优先级）：

      - 正式版规格（`latest` 等）→ `remotes`；
      - 开发版规格（`isDevVersionSpec`）→ `<npm><dev remote=...>`；未配置 `<dev>` 时返回**空列表**，
        表示开发版不代理上游（`fetch` / `fetchPackument` 只认本地已有文件）。

      上游仍然只取一个，不做交叉回落——开发版与正式版是两套来源，混着试会让「这个版本到底
      从哪来」不可预期；`1.0.0-rc.1` 这类**正式 registry 上的预发布版**由 `isDevVersionSpec`
      的判定排除在开发版之外（详见该函数）。
      解析出具体版本后也会走这里：`0.0.4-dev.2` 这类具体开发版版本同样只回 dev 上游。
  */
  const(string[]) upstreamsFor(string versionSpec) const {
    if (!isDevVersionSpec(versionSpec))
      return remotes;
    return devRemote.length > 0 ? [devRemote] : [];
  }

  /** 全部配置过的上游（正式版优先，`<dev>` 在后，去重）。

      packument 的 URL（`/{name}`）不带版本，判定不了正式版/开发版，而客户端只会读我们发的
      那一份文档——因此交付路径要把两个上游的 packument 都取回来合并（见 `fetchPackument`）。
  */
  const(string[]) allUpstreams() const {
    string[] result;
    foreach (base; remotes ~ devRemote)
      if (base.length > 0 && !result.canFind(base))
        result ~= base;
    return result;
  }

  /** 返回本地 tgz 路径（与 NpmRepoConfig.localTarball 一致）。
      使用 scopePart 作为路径首段，无 scope 时用 "_"，避免 unscoped 包名与 scope 名冲突（如 vue 与 @vue/vue）。
  */
  string localTarball(string scopePart, string namePart, string versionPart) const {
    string scopeDir = (scopePart.length > 0 && scopePart != "_") ? scopePart : "_";
    string tarballName = namePart ~ "-" ~ versionPart ~ ".tgz";
    return base ~ "/" ~ scopeDir ~ "/" ~ namePart ~ "/" ~ versionPart ~ "/" ~ tarballName;
  }

  /** 按 NPM 规范拼接 tarball URL：{registry}/{packageName}/-/{name}-{version}.tgz
  */
  string tarballUrl(string scopePart, string namePart, string versionPart, string registryBase) const {
    string packageName = (scopePart.length > 0 && scopePart != "_") ? "@" ~ scopePart ~ "/" ~ namePart
      : namePart;
    string pathEnc = packageName.encodeComponent;
    string tarballName = namePart ~ "-" ~ versionPart ~ ".tgz";
    return registryBase ~ "/" ~ pathEnc ~ "/-/" ~ tarballName;
  }

  /** 若本地已有 tgz 返回 true；否则按 `versionPart` 对应的上游列表顺序直接请求 tarball URL
      下载（开发版走 `<npm><dev>`，未配置时不下上游），成功返回 true。
  */
  bool fetch(string scopePart, string namePart, string versionPart) const {
    return fetch(scopePart, namePart, versionPart, upstreamsFor(versionPart));
  }

  /** 同 `fetch`，但由调用方显式指定上游列表。

      `resolve` 已按原始规格（tag）选定来源后，取 tgz 要沿用同一份上游：解析出的具体版本未必能
      单凭版本号判定来源（如 tag `next` 解析成 `1.0.0-next.1`，标识 `next` 不在 `developmentIds`
      里），否则会出现「packument 取自 dev 上游、tgz 却去正式版上游找」的错配。
  */
  bool fetch(string scopePart, string namePart, string versionPart, const(string[]) upstreams) const {
    auto local = localTarball(scopePart, namePart, versionPart);
    if (exists(local))
      return true;
    foreach (registryBase; upstreams) {
      string url = tarballUrl(scopePart, namePart, versionPart, registryBase);
      logInfo("Downloading %s", url);
      if (curlDownload(url, local)) {
        return true;
      }
    }
    return false;
  }

  /** 包元数据（packument）：本地有 `{base}/{pkg}` 返回 true；
      否则按同一相对路径从 `versionSpec` 对应的上游列表拉取（与 maven 侧 `GavRepo.fetch` 同口径，
      只接受包名路径）。dist-tag 必须是开发版 tag（`dev`/`next` 等）时才会去 `<npm><dev>` 找
      packument（见 `resolveVersion`）。`force` 为真时忽略本地已有文件、重新拉取（并入，
      见 `fetchPackumentFrom`）。

      元数据由发布方产出——本地发布走 `micdn install`（`micdn.npm.packument`）写盘，代理场景直接取
      上游 registry 的 packument，micdn 不自行拼装。
  */
  bool fetchPackument(string ruri, string versionSpec, bool force = false) const {
    return fetchPackumentFrom(ruri, upstreamsFor(versionSpec), force);
  }

  /** packument 的 HTTP 交付路径：URL（`/{name}` 或 `/@scope/{name}`）不含版本，判定不了正式版/
      开发版，故把所有上游的文档都取回来并入同一份（`allUpstreams`，正式版优先、去重）——
      客户端只读我们发的这一份，dev 与 latest 两个 tag 必须同时齐全。
  */
  bool fetchPackument(string ruri) const {
    // packument 的 URL 不带版本，判定不了正式版/开发版：两个上游都取回来并入同一份文档
    // （客户端只读我们发的这一份，dev tag 必须在这里就齐全）。
    return fetchPackumentFrom(ruri, allUpstreams(), false);
  }

  /** 逐一尝试 `upstreams`，每一份成功的上游文档都并入本地 packument（见 `mergeUpstreamPackument`），
      任一成功即返回 true（`force` 为假且本地已有文件时直接成功，不回源）。

      上游文档先落到临时文件再合并：直接下到 packument 路径会把另一个上游的版本整份丢掉。
      合并失败（如上游返回的不是 JSON）时退回「原样落盘」——拿到的 packument 绝不能丢。
  */
  private bool fetchPackumentFrom(string ruri, const(string[]) upstreams, bool force) const {
    if (!isPackageUri(ruri))
      return false;
    auto local = base ~ ruri;
    if (!force && exists(local))
      return true;
    bool fetched;
    foreach (registryBase; upstreams) {
      string url = registryBase ~ ruri;
      auto incoming = dirName(local) ~ "/." ~ baseName(local) ~ ".incoming";
      scope (exit)
        if (exists(incoming))
          remove(incoming);
      logInfo("Downloading %s", url);
      if (!curlDownload(url, incoming))
        continue;
      fetched = true;
      try
        mergeUpstreamPackument(base, ruri, originPlaceholder ~ mountNpm, incoming);
      catch (Exception e) {
        logWarn("npm packument merge failed for %s - %s", ruri, e.msg);
        mkdirRecurse(dirName(local));
        copy(incoming, local);
      }
    }
    return fetched;
  }

  /** 从本地 packument 读一个 dist-tag；文件不存在 / tag 缺失 / JSON 非法都返回 null。
  */
  private string localTag(string ruri, string tag) const {
    auto local = base ~ ruri;
    if (!exists(local))
      return null;
    string ver;
    try {
      auto doc = parseJSON(cast(string) read(local));
      if (doc.type == JSONType.object) {
        if (auto tags = "dist-tags" in doc.object) {
          if (auto tagged = tag in tags.object) {
            if (tagged.type == JSONType.string)
              ver = tagged.str;
          }
        }
      }
    } catch (Exception e) {
      logWarn("npm packument is not readable: %s - %s", local, e.msg);
      return null;
    }
    return ver.length > 0 ? ver : null;
  }

  /** 版本规格 → 具体版本：具体版本（`isConcreteVersion`）原样返回；否则当作 dist-tag
      （`dev`/`next`/`latest` 等），取 packument 的 `dist-tags` 解析。解析不出返回 null。

      正式版与开发版共用一个本地 base，而一个包的 packument 只有一份 `{base}/{pkg}`：它可能来自
      `micdn install`，也可能来自正式版或 `<npm><dev>` 的某个上游，因此 dist-tags 未必齐全。
      查找分两步：
     1. 先读本地已有 packument，命中即返回（`install` 产出的元数据通常最全）；
     2. 本地没有该 tag 时，按 `versionSpec` 对应的上游（`dev` 走 `<npm><dev>`，`latest` 走正式版
         `remotes`）重新拉取 packument 后再读一次。拉取是**并入**式的（`mergeUpstreamPackument`
         把上游文档与已有文件、本地已装入的版本合成一份），所以「开发版上游只有 dev tag、
         正式版上游只有 latest」不会互相遮蔽。
  */
  string resolveVersion(string scopePart, string namePart, string versionSpec) const {
    auto spec = versionSpec.strip;
    if (isConcreteVersion(spec))
      return spec;

    auto ruri = packageUri(scopePart, namePart);
    if (auto ver = localTag(ruri, spec))
      return ver;
    if (fetchPackument(ruri, spec, true))
      if (auto ver = localTag(ruri, spec))
        return ver;
    logWarn("npm dist-tag %s not found in %s", spec, ruri);
    return null;
  }
}

/** packument 的路径形态（相对仓库根）：`/{name}` 或 `/@scope/{name}`。 */
string packageUri(string scopePart, string namePart) {
  return (scopePart.length > 0 && scopePart != "_") ? "/@" ~ scopePart ~ "/" ~ namePart
    : "/" ~ namePart;
}

/** 版本规格是否为具体版本：以数字开头（`1.2.3`、`0.0.3-dev.2`）或 `v` + 数字。

    其余（`dev`/`next`/`latest` 等）按 npm 的 dist-tag 处理——先取 packument 才能得到具体版本
    （见 `NpmRepo.resolveVersion`）。
*/
bool isConcreteVersion(string versionSpec) {
  auto v = versionSpec.strip;
  if (v.length == 0)
    return false;
  if (v[0] >= '0' && v[0] <= '9')
    return true;
  return v.length > 1 && (v[0] == 'v' || v[0] == 'V') && v[1] >= '0' && v[1] <= '9';
}

/// 版本里的「开发版」预发布标识（`1.0.0-dev.2` 的 `dev`）：这些版本来自开发仓库。
immutable string[] developmentIds = [
  "dev", "snapshot", "local", "nightly", "test"
];

/** 版本规格是否开发版：预发布**标识**是开发标识（`0.0.3-dev.2`、`1.0-SNAPSHOT.1`），
    或规格本身是预发布通道 tag（`prereleaseChannels`：dev/next/beta/rc/alpha/canary）。
    `latest` 等正式 tag 不算。

    只认开发标识而不是「版本里有没有 `-`」：`1.0.0-rc.1`、`19.0.0-beta.2`、`2.0.0-20240101`
    这类预发布版本在正式 registry 上是正常发布（如 react 的 rc 版本），按旧判定会被路由到
    `<dev>`；未配置 `<dev>` 时直接 404，比「只代理正式版」还差。`rc`/`beta`/`alpha` 仍作为
    *通道 tag* 参与 dist-tag 推导（`prereleaseChannels`），只是不再据此判断版本来源。

    命中时回源走 `<npm><dev remote=...>`（未配置则不代理，见 `NpmRepo.upstreamsFor`）。
*/
bool isDevVersionSpec(string versionSpec) {
  auto v = versionSpec.strip;
  if (v.length == 0)
    return false;
  auto dash = v.indexOf('-');
  if (dash > 0) {
    auto id = v[dash + 1 .. $];
    // 预发布标识到下一个分隔符为止：`dev.2` → `dev`、`canary-abc` → `canary`
    size_t end = size_t.max;
    foreach (sep; ['.', '+', '-']) {
      auto at = id.indexOf(sep);
      if (at >= 0 && at < end)
        end = at;
    }
    if (end != size_t.max)
      id = id[0 .. end];
    return developmentIds.canFind(id.toLower);
  }
  return prereleaseChannels.canFind(v.toLower);
}

/** 取回一个 npm 包规格的 tgz（`resolve` 部署 www/static 时用），返回本地落盘路径；失败返回 null。

    - 规格里的版本可能是 dist-tag（`dev`/`latest`），先经 `NpmRepo.resolveVersion` 解析成具体版本；
    - 本地缓存已有（`{base}/{scope|_}/{name}/{version}/`）时不再访问上游；
    - 需要回源时由 `NpmRepo.fetch` 取 tgz，上游沿用**原始规格**选出的那份（与 `resolveVersion`
      取 packument 的来源一致）：开发版走 `<npm><dev>` 的 remote，未配置则不下上游（返回 null，
      除非本地已装入）；正式版走 `<npm><remote>`。这样 tag `next` 解析成 `1.0.0-next.1` 后
      仍从同一个上游取 tgz，不会因版本标识不同而错配来源。
*/
string fetchNpmTarball(NpmRepo repo, string scopePart, string namePart, string versionSpec) {
  auto ver = repo.resolveVersion(scopePart, namePart, versionSpec);
  if (ver is null)
    return null;
  if (!repo.fetch(scopePart, namePart, ver, repo.upstreamsFor(versionSpec)))
    return null;
  return repo.localTarball(scopePart, namePart, ver);
}

/// `fetchNpmTarball` 的配置版：本地仓库即 `<npm base>`（正式版与开发版共用）。
string fetchNpmTarball(MicdnConfig config, string scopePart, string namePart, string versionSpec) {
  return fetchNpmTarball(NpmRepo.build(config), scopePart, namePart, versionSpec);
}

/** 包名路径：`/name`（unscoped）或 `/@scope/name`（scoped）——即 packument 的路径形态。
    其余（根、目录、深路径、非 @ 的两段路径）都返回 false，避免把任意路径当包名去上游探测。 */
bool isPackageUri(string ruri) {
  if (ruri.length < 2 || ruri[$ - 1] == '/')
    return false;
  auto tail = ruri[1 .. $];
  auto slash = tail.indexOf('/');
  if (slash < 0)
    return tail[0] != '@';
  return tail.startsWith("@") && slash > 1 && slash < tail.length - 1
    && tail[slash + 1 .. $].indexOf('/') < 0;
}
