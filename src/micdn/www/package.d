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
/// WWW 文档子模块：每个 doc 含至多一个 dir/npm/zip，按 endpoint 挂载，不提供目录列表。

import std.file;
import std.path;
import std.string;

import vibe.core.log;

import micdn.fs.file;
import micdn.model;
import micdn.npm;
import micdn.web.file;

/// 单个 doc 的本地仓库，根目录为 base，内容来自一个 dir/jar/zip 提供者。
class WwwDocRepo {
  /// 该 doc 的本地根目录
  const string base;

  this(string base) {
    this.base = base;
  }

  /** 根据逻辑 URI 解析出对应的本地文件路径。

      路径中含 ".." 或文件不存在时返回 null。不支持逗号合并。解析目录请求，尝试返回 index.html；无列表功能。
      若为目录且存在 index.html 则返回其路径，否则返回 null。
      Params:
          uri = 逻辑 URI（相对该 doc 的 endpoint）

      Returns:
          本地绝对路径，失败返回 null
  */
  string get(string uri) const {
    if (uri.indexOf("..") > -1)
      return null;
    auto location = base ~ uri;
    if(exists(location)){
      if (std.file.isDir(location)){
        auto indexPath = location ~ "/index.html";
        if (exists(indexPath)){
          return indexPath;
        }
      }else{
        return location;
      }
    }
    return null;
  }

  /**
  */

  /** 判断路径是否为目录。
  */
  bool isDirectory(string uri) const {
    if (uri.indexOf("..") > -1)
      return false;
    auto path = base ~ uri;
    return exists(path) && std.file.isDir(path);
  }

  /** 根据全局配置构建指定 doc 的本地仓库并返回仓库实例。
  */
  static WwwDocRepo build(MicdnConfig config, const WwwDocConfig doc) {
    auto www = config.www;
    auto base = www.base;
    auto slug = doc.location.length > 1 ? doc.location[1 .. $].replace("/", "_") : "root";
    auto docBase = base ~ "/" ~ slug;

    if (exists(docBase)) {
      setWritable(docBase);
    }
    mkdirRecurse(docBase);

    auto p = doc.provider;
    if (DirProvider dp = cast(DirProvider) p) {
      if (exists(dp.location)) {
        logInfo("Linking " ~ dp.location ~ " to " ~ docBase);
        makeSymlink(dp.location, docBase);
      } else {
        logWarn("Cannot link " ~ dp.location ~ " to " ~ docBase);
      }
    } else if (NpmProvider np = cast(NpmProvider) p) {
      string scopePart, namePart, versionPart;
      parsePackageSpec(np.packageSpec, scopePart, namePart, versionPart);
      if (namePart.length == 0 || versionPart.length == 0) {
        logWarn("Invalid npm package spec: %s", np.packageSpec);
      } else {
        auto npmRepo = NpmRepo.build(config);
        if (npmRepo.fetch(scopePart, namePart, versionPart)) {
          auto tgzPath = npmRepo.localTarball(scopePart, namePart, versionPart);
          auto extractDir = docBase ~ "/.npm_extract";
          if (extractTgz(tgzPath, extractDir) > 0) {
            auto innerDir = extractDir ~ "/package/" ~ np.dir;
            if (exists(innerDir) && isDir(innerDir)) {
              copyDirContents(innerDir, docBase);
            } else {
              logWarn("Cannot find %s in %s", np.dir, tgzPath);
            }
          }
          if (exists(extractDir)) {
            rmdirRecurse(extractDir);
          }
        } else {
          logWarn("Cannot resolve npm package %s", np.packageSpec);
        }
      }
    } else if (ZipProvider zp = cast(ZipProvider) p) {
      logInfo("Mounting %s", zp.file);
      auto count = refreshUnzip(zp.file, docBase, zp.dir.length ? zp.dir : null);
      if (count == 0) {
        logWarn("Cannot find %s in %s", zp.dir, zp.file);
      }
    }

    setReadOnly(docBase);
    return new WwwDocRepo(docBase);
  }

  private static void mount(string zipfile, string base, string dir) {
    logInfo("Mounting %s", zipfile);
    auto count = refreshUnzip(zipfile, base, dir);
    if (count == 0) {
      logWarn("Cannot find %s in %s", dir, zipfile);
    }
  }
}
