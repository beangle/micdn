/* Copyright (C) 2023 Beangle
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

module micdn.www;
/// WWW 静态内容：构建时按 `<doc location>` 挂载到 `www.base` 下同名路径，运行时 `base ~ httpPath` 直接读盘。

import std.file;
import std.path : buildPath;

import vibe.core.log;

import micdn.fs.file;
import micdn.model;
import micdn.npm;
import micdn.web.file;
import micdn.web;

/// `www.base` 下的统一仓库：磁盘布局与 URL 一致（`/manual/foo` → `{base}/manual/foo`）。
class WwwRepo {
  const string base;

  this(string base) {
    this.base = base;
  }

  static WwwRepo build(MicdnConfig config) {
    auto wwwBase = config.www.base;
    foreach (doc; config.www.docs) {
      if (!isSafePathSegments(doc.location)) {
        throw new Exception("www doc location must not contain '.' or '..' path segments: " ~ doc.location);
      }
      if (doc.provider is null) {
        logWarn("Www doc provider is null: %s", doc.location);
        continue;
      }
      logInfo("Mounting www %s", doc.location);
      mountDoc(config, doc);
    }
    return new WwwRepo(wwwBase);
  }

  /** 按 HTTP 路径解析本地文件（须为 `getPath` 已解码路径；规范化并限制在 `base` 下）。
  */
  string get(string uri) const {
    auto location = resolveRepositoryPath(base, uri);
    if (location is null)
      return null;
    if (exists(location)) {
      if (std.file.isDir(location)) {
        auto indexPath = buildPath(location, "index.html");
        if (exists(indexPath))
          return indexPath;
      } else {
        return location;
      }
    }
    return null;
  }

  /** 将 doc 挂载到 `www.base` 下与 `location` 同构的目录（如 `/mobile/student` → `{base}/mobile/student`）。
  */
  private static void mountDoc(MicdnConfig config, const WwwDocConfig doc) {
    auto www = config.www;
    auto docDir = resolveRepositoryPath(www.base, doc.location);
    if (docDir is null) {
      logWarn("Invalid www doc path: %s", doc.location);
      return;
    }

    if (exists(docDir))
      setWritable(docDir);
    mkdirRecurse(docDir);
    auto p = doc.provider;
    if (DirProvider dp = cast(DirProvider) p) {
      if (exists(dp.location)) {
        logInfo("Linking " ~ dp.location ~ " to " ~ docDir);
        makeSymlink(dp.location, docDir);
      } else {
        logWarn("Cannot link " ~ dp.location ~ " to " ~ docDir);
      }
    } else if (NpmProvider np = cast(NpmProvider) p) {
      string scopePart, namePart, versionPart;
      parsePackageSpec(np.packageSpec, scopePart, namePart, versionPart);
      if (namePart.length == 0 || versionPart.length == 0) {
        logWarn("Invalid npm package spec: %s", np.packageSpec);
      } else {
        logInfo("Mounting %s", np.packageSpec);
        auto npmRepo = NpmRepo.build(config);
        if (npmRepo.fetch(scopePart, namePart, versionPart)) {
          auto tgzPath = npmRepo.localTarball(scopePart, namePart, versionPart);
          if (!extractTgzToDocBase(tgzPath, docDir, "package/" ~ np.dir))
            logWarn("Failed to extract %s to %s", tgzPath, docDir);
        } else {
          logWarn("Cannot resolve npm package %s", np.packageSpec);
        }
      }
    } else if (ZipProvider zp = cast(ZipProvider) p) {
      logInfo("Mounting %s", zp.file);
      auto count = refreshUnzip(zp.file, docDir, zp.dir);
      if (count == 0)
        logWarn("Cannot find %s in %s", zp.dir, zp.file);
    }

    setReadOnly(docDir);
  }
}
