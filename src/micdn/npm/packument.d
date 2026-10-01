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

module micdn.npm.packument;
/// 本地发布：把 npm 包 tgz 装入本地缓存目录，并按目录内容生成/刷新 packument 元数据（`micdn install`）。

import std.algorithm;
import std.array;
import std.ascii : isAlphaNum;
import std.base64;
import std.conv;
import std.datetime;
import std.digest : toHexString, LetterCase;
import std.digest.sha : sha1Of, sha512Of;
import std.file;
import std.format : format;
import std.json;
import std.path;
import std.string;

import vibe.core.log;

import micdn.fs.tar : readTgzEntry;
import micdn.web : normalizeBasePath;

/// tarball 内包清单的条目名（npm 打包格式固定 `package/` 前缀）。
enum packageManifestEntry = "package/package.json";

/** packument 里 `dist.tarball` 的 origin 占位符。

    本地发布写入 `{origin}/npm/{pkg}/-/{name}-{version}.tgz`（而非写死某个主机），
    交付时由 `micdn.npm.web` 换成请求实际 origin（`micdn.web.origin.getOrigin`）。
    上游代理来的 packument 是绝对地址，不含占位符，交付时原样发送。
*/
enum originPlaceholder = "{origin}";

/// 认得的预发布通道（`1.2.3-dev.4` 的 `dev`），与 `npm publish --tag` 的常见用法一致。
immutable string[] prereleaseChannels = ["dev", "next", "beta", "rc", "alpha", "canary"];

/// 本地缓存中的一个版本工件（版本目录名即版本号，tarball 名固定 `{name}-{version}.tgz`）。
private struct VersionHit {
  string ver;
  string file;
  ulong size;
  SysTime modified;
}

/// `installTarball` 的结果（供 CLI 打印）。
struct InstallResult {
  /// 包全名（scoped 带 `@`）
  string name;
  string ver;
  /// 落盘的 tgz 路径
  string tarball;
  /// 写出的 packument 路径
  string packument;
  /// 对外 tarball URL
  string url;
  /// 该包当前全部可读版本（版本升序）
  string[] versions;
}

/** 把 `tgzFile` 按 npm 目录规范装入 `{base}/{scope|_}/{name}/{version}/{name}-{version}.tgz`，
    并在 `{base}/{pkg}` 写出 packument（`dist.tarball` = `registryBase` + npm 官方 URL 路径）。

    CLI 传入的 `registryBase` 通常是 `{origin}/npm`（只写占位符，交付期替换成实际 origin，见 `originPlaceholder`）；
    测试或特殊场景也可传绝对地址，写死到 packument 里。

    元数据一律从 tarball 内的 `package/package.json` 推导，与工件不分家；已有 packument（例如上游
    代理来的版本）会与本地版本合并，不会被覆盖丢失：

    - `dist.integrity` / `dist.shasum` 由 tgz 字节算出；
    - `dist-tags.latest` 取合并后最高正式版（只有预发布时退化为最高版本），预发布版本按
      `dev` / `next` / `beta` / `rc` / `alpha` / `canary` 通道各生成一个 tag；
    - 已有 packument 里仍然指向现有版本的自定义 tag 会保留，`extraTag` 非空时再把本次版本挂上去；
    - `time` 取各版本 tgz 的 mtime。

    失败抛 Exception（消息面向使用者，CLI 直接打印）。
*/
InstallResult installTarball(string base, string tgzFile, string registryBase, string extraTag = "") {
  if (!exists(tgzFile) || isDir(tgzFile))
    throw new Exception("npm package tgz not found: " ~ tgzFile);
  if (registryBase.length == 0)
    throw new Exception("registry base must not be empty");
  if (extraTag.length > 0)
    validateTag(extraTag);

  JSONValue manifest;
  if (!readManifest(tgzFile, manifest))
    throw new Exception("cannot read " ~ packageManifestEntry ~ " from " ~ tgzFile);
  auto name = manifestField(manifest, "name");
  auto ver = manifestField(manifest, "version");
  if (name is null || ver is null)
    throw new Exception(packageManifestEntry ~ " lacks name or version: " ~ tgzFile);
  validatePackageName(name);
  validateVersion(ver, tgzFile);

  auto segs = name.split("/");
  auto scoped = segs.length == 2;
  auto scopePart = scoped ? segs[0][1 .. $] : "_";
  auto bare = segs[$ - 1];

  auto root = normalizeBasePath(base);
  auto dest = root ~ "/" ~ scopePart ~ "/" ~ bare ~ "/" ~ ver ~ "/" ~ bare ~ "-" ~ ver ~ ".tgz";
  mkdirRecurse(dirName(dest));
  if (absolutePath(tgzFile) != absolutePath(dest))
    copy(tgzFile, dest);

  auto packument = root ~ "/" ~ (scoped ? "@" ~ scopePart ~ "/" ~ bare : bare);
  auto versions = refreshPackument(root, name, registryBase, ver, extraTag);
  return InstallResult(name, ver, dest, packument, tarballUrl(registryBase, name, bare, ver),
      versions);
}

/** 读取 tarball 内的 `package/package.json`；损坏或缺失返回 false 并记日志。 */
private bool readManifest(string tgzFile, out JSONValue manifest) {
  manifest = JSONValue.init;
  ubyte[] raw;
  if (!readTgzEntry(tgzFile, packageManifestEntry, raw)) {
    logWarn("npm install: %s has no %s", tgzFile, packageManifestEntry);
    return false;
  }
  try {
    manifest = parseJSON(cast(string) raw);
  } catch (Exception e) {
    logWarn("npm install: invalid %s in %s - %s", packageManifestEntry, tgzFile, e.msg);
    return false;
  }
  if (manifest.type != JSONType.object) {
    logWarn("npm install: %s in %s is not an object", packageManifestEntry, tgzFile);
    return false;
  }
  return true;
}

/** 代理场景的合并入口：把本地已装入的版本并入 `{base}/{pkg}`（`ruri` 为 `/name` 或 `/@scope/name`）。

    从上游拿到的 packument 只含上游自己的版本；而正式版与开发版共用同一份 `{base}/{pkg}`，
    一份文件里的 dist-tags 因此可能缺失另一个来源的 tag。每次 packument 落盘后调用本函数，
    把本地 tgz 目录里的版本补回去，交付期（与 `resolveVersion`）就有完整的 dist-tags。

    本地一个 tgz 都没有时不重写 packument。
*/
void mergeLocalVersions(string base, string ruri, string registryBase) {
  if (ruri.length < 2 || ruri[0] != '/' || !isPackageName(ruri[1 .. $]))
    return;
  auto name = ruri[1 .. $];
  auto segs = name.split("/");
  auto scopePart = segs.length == 2 ? segs[0][1 .. $] : "_";
  auto root = normalizeBasePath(base);
  if (!exists(root ~ "/" ~ scopePart ~ "/" ~ segs[$ - 1]))
    return;
  try {
    refreshPackument(root, name, registryBase, "", "");
  } catch (Exception e) {
    // 合并只是尽力而为：packument 已经拿到手，不能因为本地目录有杂音就让交付失败。
    logWarn("npm packument merge skipped for %s - %s", ruri, e.msg);
  }
}

/** 扫描本地版本目录，把 `{base}/{pkg}` 的 packument 刷新为「已有版本 + 本地版本」的合并结果，
    返回合并后的版本列表（升序）。

    - 以文件里已有的 packument 为基础：保留上游代理来的版本条目（含绝对 tarball 地址）、`time`
      与其余顶层字段（`readme`、`maintainers` 等）；
    - 本地 tgz 目录里的版本从 tarball 内清单重算并覆盖同名条目——本地工件是权威，
      `dist.integrity`/`shasum` 取自本地字节，`tarball` = `registryBase` + npm 官方 URL 路径；
    - `dist-tags.latest` 取合并后最高的正式版（只有预发布时退化为最高版本），预发布通道 tag 同理；
      仍然指向现存版本的其它 tag 保留，`extraTag` 非空时挂到 `installedVer` 上；
    - `time` 各版本取本地 tgz 的 mtime（非本地版本保持已有值），`created`/`modified` 取本地最早/最新一次装入。

    `installedVer` 非空时必须能在合并结果里找到（`install` 刚复制过 tgz，必然满足）；
    没有任何可读版本时抛 Exception。
*/
private string[] refreshPackument(string root, string name, string registryBase,
    string installedVer, string extraTag) {
  auto segs = name.split("/");
  auto scoped = segs.length == 2;
  auto scopePart = scoped ? segs[0][1 .. $] : "_";
  auto bare = segs[$ - 1];
  auto versionsDir = root ~ "/" ~ scopePart ~ "/" ~ bare;
  auto packumentFile = root ~ "/" ~ (scoped ? "@" ~ scopePart ~ "/" ~ bare : bare);

  VersionHit[] hits;
  if (exists(versionsDir) && isDir(versionsDir))
    foreach (entry; dirEntries(versionsDir, SpanMode.shallow)) {
      if (!entry.isDir)
        continue;
      auto ver = baseName(entry.name);
      auto file = entry.name ~ "/" ~ bare ~ "-" ~ ver ~ ".tgz";
      if (!exists(file) || isDir(file))
        continue;
      hits ~= VersionHit(ver, file, getSize(file), timeLastModified(file));
    }
  hits.sort!((a, b) => compareVersions(a.ver, b.ver) < 0);

  // 以上游/上次 install 写下的 packument 为基础（读不出时按空处理）。
  JSONValue doc = readPackument(packumentFile);
  JSONValue[string] mergedVersions;
  JSONValue[string] mergedTime;
  JSONValue[string] tagValues;
  if (auto existing = "versions" in doc.object)
    if (existing.type == JSONType.object)
      foreach (ver, entry; existing.object)
        mergedVersions[ver] = entry;
  if (auto existing = "time" in doc.object)
    if (existing.type == JSONType.object)
      foreach (key, entry; existing.object)
        mergedTime[key] = entry;
  foreach (tag, tagged; preservedTags(doc))
    tagValues[tag] = JSONValue(tagged);

  // 本地版本覆盖同名条目：dist 与清单都从本地 tgz 重算。
  JSONValue[string] localManifests;
  foreach (hit; hits) {
    JSONValue manifest;
    if (!readManifest(hit.file, manifest))
      continue;

    // 与 npm 一致：发布产物不带打包脚本、开发依赖与发布配置。
    foreach (key; ["scripts", "devDependencies", "publishConfig", "pnpm"])
      manifest.object.remove(key);

    auto bytes = cast(const(ubyte)[]) std.file.read(hit.file);
    auto dist = JSONValue.emptyObject;
    dist["tarball"] = JSONValue(tarballUrl(registryBase, name, bare, hit.ver));
    dist["integrity"] = JSONValue(("sha512-" ~ Base64.encode(sha512Of(bytes))).idup);
    dist["shasum"] = JSONValue(toHexString!(LetterCase.lower)(sha1Of(bytes)).idup);
    manifest["dist"] = dist;

    mergedVersions[hit.ver] = manifest;
    mergedTime[hit.ver] = JSONValue(isoTime(hit.modified));
    localManifests[hit.ver] = manifest;
  }
  if (mergedVersions.length == 0)
    throw new Exception("no readable npm version under " ~ versionsDir);
  if (installedVer.length > 0 && !(installedVer in mergedVersions))
    throw new Exception("installed " ~ installedVer ~ " is unreadable in " ~ versionsDir);

  string[] versions = mergedVersions.keys;
  versions.sort!((a, b) => compareVersions(a, b) < 0);

  // latest = 合并后最高的正式版；只有预发布时退化为最高版本。
  string latestTag;
  foreach (ver; versions)
    if (prereleaseOf(ver).length == 0)
      latestTag = ver;
  if (latestTag.length == 0)
    latestTag = versions[$ - 1];

  JSONValue tags = JSONValue.emptyObject;
  foreach (tag, tagged; tagValues)
    if (!isDerivedTag(tag) && tagged.str in mergedVersions)
      tags[tag] = tagged;
  tags["latest"] = JSONValue(latestTag);
  foreach (channel; prereleaseChannels) {
    string best;
    foreach (ver; versions)
      if (channelOf(ver) == channel)
        best = ver;
    if (best.length > 0)
      tags[channel] = JSONValue(best);
  }
  if (extraTag.length > 0)
    tags[extraTag] = JSONValue(installedVer);

  JSONValue timeJson = JSONValue.emptyObject;
  foreach (key, entry; mergedTime)
    timeJson[key] = entry;
  if (hits.length > 0) {
    timeJson["created"] = JSONValue(isoTime(hits[0].modified));
    timeJson["modified"] = JSONValue(isoTime(hits[$ - 1].modified));
  }

  JSONValue versionsJson = JSONValue.emptyObject;
  foreach (ver, entry; mergedVersions)
    versionsJson[ver] = entry;

  doc["_id"] = JSONValue(name);
  doc["name"] = JSONValue(name);
  doc["dist-tags"] = tags;
  doc["versions"] = versionsJson;
  doc["time"] = timeJson;
  // 顶层摘要字段：优先取本地 latest 版本（与旧行为一致）；latest 来自上游时只补空缺，不覆盖。
  JSONValue topManifest;
  bool fromLatest;
  if (auto value = latestTag in localManifests) {
    topManifest = *value;
    fromLatest = true;
  } else {
    foreach (ver; versions)
      if (auto value = ver in localManifests) {
        topManifest = *value;
        break;
      }
  }
  if (topManifest.type == JSONType.object) {
    foreach (key; ["description", "license", "homepage", "repository", "bugs", "keywords"]) {
      if (!fromLatest && key in doc.object)
        continue;
      if (auto value = key in topManifest.object)
        doc[key] = *value;
    }
  }

  mkdirRecurse(dirName(packumentFile));
  write(packumentFile, toJSON(doc, true) ~ "\n");
  return versions;
}

/// 读已有 packument（缺失/不可读时返回空对象，不阻断发布）。
private JSONValue readPackument(string packumentFile) {
  if (!exists(packumentFile) || isDir(packumentFile))
    return JSONValue.emptyObject;
  try {
    auto doc = parseJSON(readText(packumentFile));
    if (doc.type == JSONType.object)
      return doc;
  } catch (Exception e) {
    logWarn("npm install: ignoring unreadable packument %s - %s", packumentFile, e.msg);
  }
  return JSONValue.emptyObject;
}

/// 已有 packument 的 dist-tags（只保留字符串值）。
private string[string] preservedTags(JSONValue doc) {
  string[string] tags;
  if (auto value = "dist-tags" in doc.object) {
    if (value.type == JSONType.object)
      foreach (tag, tagged; value.object)
        if (tagged.type == JSONType.string)
          tags[tag] = tagged.str;
  }
  return tags;
}

/// 包名形态（`name` 或 `@scope/name`）——用于把 packument 的 uri 还原成包名。
private bool isPackageName(string name) {
  auto segs = name.split("/");
  if (segs.length == 1)
    return segs[0].length > 0 && segs[0][0] != '@';
  return segs.length == 2 && segs[0].length > 1 && segs[0][0] == '@' && segs[1].length > 0;
}

/// 由目录内容推导出来的 tag（每次刷新都会重算，不保留历史值）。
private bool isDerivedTag(string tag) {
  return tag == "latest" || prereleaseChannels.canFind(tag);
}

/// 包名：`name` 或 `@scope/name`；只放行 npm 合法字符，且各段不得为 `.` / `..`（路径安全）。
private void validatePackageName(string name) {
  auto segs = name.split("/");
  if (segs.length > 2)
    throw new Exception("invalid npm package name (too many '/'): " ~ name);
  if (segs.length == 2) {
    if (segs[0].length < 2 || segs[0][0] != '@')
      throw new Exception("invalid scoped npm package name: " ~ name);
  } else if (segs[0].length > 0 && segs[0][0] == '@') {
    throw new Exception("invalid scoped npm package name (missing '/'): " ~ name);
  }
  foreach (seg; segs) {
    if (seg.length == 0 || seg == "." || seg == ".." || seg[0] == '.')
      throw new Exception("unsafe npm package name: " ~ name);
    foreach (c; seg)
      if (!(isAlphaNum(c) || c == '-' || c == '_' || c == '.' || c == '~' || c == '@'))
        throw new Exception("unsafe npm package name: " ~ name);
  }
}

/// 版本号：放行 semver 字符，且不得含路径分隔或为 `.` / `..`（版本号会作为目录名）。
private void validateVersion(string ver, string tgzFile) {
  if (ver.length == 0 || ver == "." || ver == "..")
    throw new Exception("unsafe npm version in " ~ tgzFile ~ ": " ~ ver);
  foreach (c; ver)
    if (!(isAlphaNum(c) || c == '-' || c == '_' || c == '.' || c == '+' || c == '~'))
      throw new Exception("unsafe npm version in " ~ tgzFile ~ ": " ~ ver);
}

/// dist-tag 名：非空、不以 `-`/`.` 开头、不含空白与 URL 特殊字符。
private void validateTag(string tag) {
  if (tag.length == 0 || tag[0] == '-' || tag[0] == '.')
    throw new Exception("invalid dist-tag: " ~ tag);
  foreach (c; tag)
    if (!(isAlphaNum(c) || c == '-' || c == '_' || c == '.'))
      throw new Exception("invalid dist-tag: " ~ tag);
}

/// `{registryBase}/{pkg}/-/{name}-{version}.tgz`
private string tarballUrl(string registryBase, string name, string bare, string ver) {
  return registryBase ~ "/" ~ name ~ "/-/" ~ bare ~ "-" ~ ver ~ ".tgz";
}

/// 从包清单取字符串字段；缺失或类型不符返回 null。
private string manifestField(JSONValue manifest, string key) {
  auto value = key in manifest.object;
  return (value is null || value.type != JSONType.string) ? null : value.str;
}

/// semver 预发布比较（[SemVer 2.0.0 §11.4](https://semver.org/lang/zh-CN/#spec-item-11)）：逐段比较，
/// 纯数字段按数值（用 `ulong` 承载，避免时间戳标识溢出），数字段低于非数字段，非数字段按 ASCII 比较，
/// 前若干段相同则段数多者大；正式版（空）大于任何预发布版。
private int comparePrerelease(string a, string b) {
  if (a.length == 0 || b.length == 0) {
    if (a.length == b.length)
      return 0;
    return a.length == 0 ? 1 : -1;
  }
  auto ia = a.split(".");
  auto ib = b.split(".");
  foreach (i; 0 .. min(ia.length, ib.length)) {
    auto x = ia[i];
    auto y = ib[i];
    auto nx = isNumericIdentifier(x);
    auto ny = isNumericIdentifier(y);
    if (nx && ny) {
      auto vx = x.to!ulong;
      auto vy = y.to!ulong;
      if (vx != vy)
        return vx < vy ? -1 : 1;
    } else if (nx != ny) {
      return nx ? -1 : 1;
    } else if (x != y) {
      return x < y ? -1 : 1;
    }
  }
  if (ia.length != ib.length)
    return ia.length < ib.length ? -1 : 1;
  return 0;
}

/// 按 semver 语义比较：先比主版本三元组，再逐段比预发布标识；正式版大于同号预发布版。
private int compareVersions(string a, string b) {
  static uint[] coreNumbers(string v) {
    uint[] nums;
    foreach (part; (v.split("-")[0]).split("."))
      nums ~= part.length > 0 && isNumericIdentifier(part) ? part.to!uint : 0;
    return nums;
  }

  auto pa = coreNumbers(a);
  auto pb = coreNumbers(b);
  foreach (i; 0 .. 3) {
    auto x = i < pa.length ? pa[i] : 0;
    auto y = i < pb.length ? pb[i] : 0;
    if (x != y)
      return x < y ? -1 : 1;
  }
  return comparePrerelease(prereleaseOf(a), prereleaseOf(b));
}

/// 预发布部分：`1.2.3-dev.4` → `dev.4`；无预发布返回空串。
private string prereleaseOf(string ver) {
  auto i = ver.indexOf('-');
  return i < 0 ? "" : ver[i + 1 .. $];
}

/// 预发布通道名：`1.2.3-dev.4` → `dev`；正式版或未约定的通道返回空串。
private string channelOf(string ver) {
  auto pre = prereleaseOf(ver);
  if (pre.length == 0)
    return "";
  auto i = pre.indexOf('.');
  auto head = i < 0 ? pre : pre[0 .. i];
  return prereleaseChannels.canFind(head) ? head : "";
}

/// semver 的「数字标识」：非空且全为 ASCII 数字。
private bool isNumericIdentifier(string s) {
  return s.length > 0 && s.all!(c => c >= '0' && c <= '9');
}

/// npm 的 ISO 时间（毫秒精度，JS `new Date` 能解析）。
private string isoTime(SysTime time) {
  auto utc = time.toUTC();
  return format("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", utc.year, utc.month, utc.day, utc.hour,
      utc.minute, utc.second, utc.fracSecs.total!"msecs" % 1000);
}
