/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.npm;
/// NPM 仓库本地缓存与从 registry 拉取 tgz。

import std.algorithm;
import std.conv;
import std.file;
import std.path;
import std.string;
import std.uri;

import vibe.core.log;

import micdn.model;
import micdn.web.file;

/** 解析 NPM 包规格 @scope/name@version 或 name@version，通过 ref 返回 (scopePart, namePart, versionPart)。
    scopePart 无 scope 时为 "_"。
*/
void parsePackageSpec(string packageSpec, ref string scopePart, ref string namePart, ref string versionPart) {
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

class NpmRepo {
  const string base;
  const string[] remotes;

  this(const string base, const string[] remotes) {
    this.base = base;
    this.remotes = remotes;
  }

  static NpmRepo build(MicdnConfig config) {
    mkdirRecurse(config.npm.base);
    return new NpmRepo(config.npm.base, config.npm.remotes);
  }

  /** 返回本地 tgz 路径（与 NpmRepoConfig.localTarball 一致）。
  */
  string localTarball(string scopePart, string namePart, string versionPart) const {
    string tarballName = (scopePart.length > 0 && scopePart != "_") ? scopePart ~ "-" ~ namePart ~ "-" ~ versionPart ~ ".tgz" : namePart ~ "-" ~ versionPart ~ ".tgz";
    return base ~ "/" ~ scopePart ~ "/" ~ namePart ~ "/" ~ versionPart ~ "/" ~ tarballName;
  }

  /** 按 NPM 规范拼接 tarball URL：{registry}/{packageName}/-/{name}-{version}.tgz
  */
  string tarballUrl(string scopePart, string namePart, string versionPart, string registryBase) const {
    string packageName = (scopePart.length > 0 && scopePart != "_") ? "@" ~ scopePart ~ "/" ~ namePart : namePart;
    string baseUrl = registryBase.endsWith("/") ? registryBase[0 .. $ - 1] : registryBase;
    string pathEnc = packageName.encodeComponent;
    string tarballName = namePart ~ "-" ~ versionPart ~ ".tgz";
    return baseUrl ~ "/" ~ pathEnc ~ "/-/" ~ tarballName;
  }

  /** 若本地已有 tgz 返回 true；否则按 remotes 顺序直接请求 tarball URL 下载，成功返回 true。
  */
  bool fetch(string scopePart, string namePart, string versionPart) const {
    auto local = localTarball(scopePart, namePart, versionPart);
    if (exists(local))
      return true;
    mkdirRecurse(dirName(local));
    foreach (registryBase; remotes) {
      string url = tarballUrl(scopePart, namePart, versionPart, registryBase);
      logInfo("Downloading %s", url);
      if (curlDownload(url, local)) {
        return true;
      }
    }
    return false;
  }
}
