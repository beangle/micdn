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
    并在 `{base}/{pkg}` 写出 packument（`dist.tarball` 用 `registryBase` 拼出）。

    元数据一律从 tarball 内的 `package/package.json` 推导，与工件不分家：

    - `dist.integrity` / `dist.shasum` 由 tgz 字节算出；
    - `dist-tags.latest` 取最高正式版（只有预发布时退化为最高版本），预发布版本按
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
  auto versions = refreshPackument(root, name, scopePart, bare, registryBase, ver, extraTag);
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

/** 扫描版本目录，重算各版本 dist 与 dist-tags，写出 `{base}/{pkg}`。返回版本列表（升序）。 */
private string[] refreshPackument(string root, string name, string scopePart, string bare,
    string registryBase, string installedVer, string extraTag) {
  auto versionsDir = root ~ "/" ~ scopePart ~ "/" ~ bare;
  auto packumentFile = root ~ "/" ~ (scopePart == "_" ? bare : "@" ~ scopePart ~ "/" ~ bare);

  VersionHit[] hits;
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

  JSONValue versionsJson = JSONValue.emptyObject;
  JSONValue timeJson = JSONValue.emptyObject;
  JSONValue latestManifest;
  auto latestTag = latestVersion(hits);
  string[] versions;
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

    versionsJson[hit.ver] = manifest;
    timeJson[hit.ver] = JSONValue(isoTime(hit.modified));
    versions ~= hit.ver;
    if (hit.ver == latestTag)
      latestManifest = manifest;
  }
  if (versions.length == 0)
    throw new Exception("no readable npm version under " ~ versionsDir);
  if (!(installedVer in versionsJson.object))
    throw new Exception("installed " ~ installedVer ~ " is unreadable in " ~ versionsDir);

  JSONValue tags = JSONValue.emptyObject;
  foreach (tag, tagged; preservedTags(packumentFile)) {
    // latest 与通道 tag 由目录内容重新推导；自定义 tag 只要版本还在就保留。
    if (!isDerivedTag(tag) && (tagged in versionsJson.object))
      tags[tag] = JSONValue(tagged);
  }
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

  timeJson["created"] = JSONValue(isoTime(hits[0].modified));
  timeJson["modified"] = JSONValue(isoTime(hits[$ - 1].modified));

  JSONValue doc = JSONValue.emptyObject;
  doc["_id"] = JSONValue(name);
  doc["name"] = JSONValue(name);
  doc["dist-tags"] = tags;
  doc["versions"] = versionsJson;
  doc["time"] = timeJson;
  if (latestManifest.type == JSONType.object) {
    foreach (key; ["description", "license", "homepage", "repository", "bugs", "keywords"]) {
      if (auto value = key in latestManifest.object)
        doc[key] = *value;
    }
  }

  mkdirRecurse(dirName(packumentFile));
  write(packumentFile, toJSON(doc, true) ~ "\n");
  return versions;
}

/// 已有 packument 的 dist-tags（读不出时返回空，不阻断发布）。
private string[string] preservedTags(string packumentFile) {
  string[string] tags;
  if (!exists(packumentFile) || isDir(packumentFile))
    return tags;
  try {
    auto doc = parseJSON(readText(packumentFile));
    if (auto value = "dist-tags" in doc.object) {
      foreach (tag, tagged; value.object)
        if (tagged.type == JSONType.string)
          tags[tag] = tagged.str;
    }
  } catch (Exception e) {
    logWarn("npm install: ignoring unreadable packument %s - %s", packumentFile, e.msg);
  }
  return tags;
}

/// 最高正式版（`hits` 已按版本升序）；只有预发布版本时退化为最高版本。
private string latestVersion(const(VersionHit[]) hits) {
  foreach_reverse (hit; hits)
    if (prereleaseOf(hit.ver).length == 0)
      return hit.ver;
  return hits[$ - 1].ver;
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
