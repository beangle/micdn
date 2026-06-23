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

import std.algorithm;
import std.file;
import std.path : baseName, buildPath, dirName;

import vibe.core.log;

import micdn.fs.file;
import micdn.model;
import micdn.npm;
import micdn.web.file;
import micdn.web;
import micdn.web.ext;

/// `www.base` 下的统一仓库：磁盘布局与 URL 一致（`/manual/foo` → `{base}/manual/foo`）。
class WwwRepo {
  const string base;
  const WwwDocConfig[] docs;

  this(string base, const WwwDocConfig[] docs = null) {
    this.base = base;
    this.docs = docs;
  }

  static WwwRepo build(MicdnConfig config) {
    auto wwwBase = config.www.base;
    prepareBase(wwwBase);
    foreach (doc; config.www.docs) {
      mountDoc(config, doc);
    }
    return new WwwRepo(wwwBase, config.www.docs);
  }

  /** 按 HTTP 路径解析本地文件（须为 `getPath` 已解码路径；规范化并限制在 `base` 下）。
    顺序：$uri → $uri/（目录 index.html）→ 所属 doc 的 `try-file`（带静态扩展名且未命中则不回退）。
  */
  string get(string uri) const {
    auto location = resolveRepositoryPath(base, uri);
    if (location !is null && exists(location)) {
      if (std.file.isDir(location)) {
        auto indexPath = buildPath(location, "index.html");
        if (exists(indexPath))
          return indexPath;
      } else {
        return location;
      }
    }

    auto doc = findDoc(uri);
    if (doc !is null && doc.tryFile.length > 0) {
      if (isStaticAsset(uri))
        return null;
      return resolveRepositoryPath(base, doc.endpoint() ~ "/" ~ doc.tryFile);
    }
    return null;
  }

  private const(WwwDocConfig) findDoc(string uri) const {
    if (docs is null)
      return null;
    size_t bestIdx = size_t.max;
    size_t bestLen = 0;
    foreach (i, d; docs) {
      auto ep = d.endpoint();
      if (uri.length < ep.length || !uri.startsWith(ep))
        continue;
      if (uri.length > ep.length && uri[ep.length] != '/')
        continue;
      if (ep.length > bestLen) {
        bestIdx = i;
        bestLen = ep.length;
      }
    }
    return bestIdx == size_t.max ? null : docs[bestIdx];
  }

  /** 将单个 www `<doc>` 挂载到 `www.base` 下与 `location` 同构的目录
    （如 `/manual` → `{base}/manual`）。供 `build` 与 `micdn … mount-www` 共用。

    按 provider 处理 dir 符号链接、npm 解压或 zip 增量解压。
    成功返回 true，失败打日志并返回 false。
  */
  static bool mountDoc(MicdnConfig config, const WwwDocConfig doc, bool force = false) {
    try {
      auto docDir = resolveRepositoryPath(config.www.base, doc.endpoint());
      assert(docDir !is null, "www doc path escapes base: " ~ doc.name);

      auto writableDir = docDir;
      if (cast(DirProvider) doc.provider)
        writableDir = dirName(docDir);
      if (!verifyMountDirWritable(writableDir)) {
        logError("Mount www %s failed: %s is not writable", doc.name, writableDir);
        return false;
      }

      if (DirProvider dp = cast(DirProvider) doc.provider) {
        if (!mountDocDir(dp, docDir))
          return false;
      } else if (NpmProvider np = cast(NpmProvider) doc.provider) {
        if (!mountDocNpm(config, np, docDir, force))
          return false;
      } else if (ZipProvider zp = cast(ZipProvider) doc.provider) {
        if (!mountDocZip(zp, docDir, force))
          return false;
      } else {
        assert(false, "unsupported www provider for " ~ doc.name);
      }

      warnMissingTryFile(config.www.base, doc);
      return true;
    } catch (Exception e) {
      logError("Mount www %s failed: %s", doc.name, e.msg);
      return false;
    }
  }

  /// mount 完成后校验 `try-file` 是否已在磁盘上；缺失则警告（运行期由 sendFile 处理 404）。
  private static void warnMissingTryFile(string wwwBase, const WwwDocConfig doc) {
    if (doc.tryFile.length == 0)
      return;
    auto path = resolveRepositoryPath(wwwBase, doc.endpoint() ~ "/" ~ doc.tryFile);
    if (path is null)
      return;
    if (!exists(path) || std.file.isDir(path))
      logWarn("www doc %s try-file %s not found at %s", doc.name, doc.tryFile, path);
  }

  /// `<dir>`：清空 `docDir` 后创建符号链接（与 static bundle 一致，不先 mkdir）。
  private static bool mountDocDir(const DirProvider dp, string docDir) {
    if (!exists(dp.location)) {
      logWarn("Cannot link " ~ dp.location ~ " to " ~ docDir);
      return false;
    }
    mkdirRecurse(dirName(docDir));
    clearDocDirForSymlink(docDir);
    logInfo("Linking " ~ dp.location ~ " to " ~ docDir);
    makeSymlink(dp.location, docDir);
    return true;
  }

  /// `<npm>`：拉取 tgz 并解压到 `docDir`。
  private static bool mountDocNpm(MicdnConfig config, const NpmProvider np, string docDir, bool force) {
    string scopePart, namePart, versionPart;
    parsePackageSpec(np.packageSpec, scopePart, namePart, versionPart);
    if (namePart.length == 0 || versionPart.length == 0) {
      logWarn("Invalid npm package spec: %s", np.packageSpec);
      return false;
    }
    auto npmRepo = NpmRepo.build(config);
    if (!npmRepo.fetch(scopePart, namePart, versionPart)) {
      logWarn("Cannot resolve npm package %s", np.packageSpec);
      return false;
    }
    auto tgzPath = npmRepo.localTarball(scopePart, namePart, versionPart);
    if (!extractTgzToDocBase(tgzPath, docDir, "package/" ~ np.dir, np.packageSpec, force)) {
      logWarn("Failed to extract %s to %s", tgzPath, docDir);
      return false;
    }
    return true;
  }

  /// `<zip>`：增量解压到 `docDir`。
  private static bool mountDocZip(const ZipProvider zp, string docDir, bool force) {
    if (refreshUnzip(zp.file, docDir, zp.dir, baseName(zp.file), force) == 0) {
      logWarn("Cannot find %s in %s", zp.dir, zp.file);
      return false;
    }
    return true;
  }

  /** 确保 `www.base` 存在且目录本身可写（见 `ensureDirWritable`，不递归子项）。 */
  static void prepareBase(string wwwBase) {
    mkdirRecurse(wwwBase);
    ensureDirWritable(wwwBase);
  }

  private static void clearDocDirForSymlink(string docDir) {
    if (!exists(docDir))
      return;
    if (isSymlink(docDir))
      remove(docDir);
    else
      rmdirRecurse(docDir);
  }
}
