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

module micdn.asset;
/// 静态资源子模块：根据配置构建/刷新本地资源仓库，并按 URI 解析并返回物理路径列表。

import std.file;
import std.path;
import std.string;

import vibe.core.log;

import micdn.fs.file;
import micdn.model;
import micdn.npm;

/// 静态资源仓库实例，持有本地根目录与目录列表开关，提供 URI 解析与文件路径查询。
class AssetRepo {
  /// 仓库根目录（本地文件系统路径）。
  const string base;

  /** 构造资源仓库实例。

      Params:
          base       = 仓库根目录
  */
  this(string base) {
    this.base = base;
  }

  /** 根据逻辑 URI 解析出对应的本地文件路径列表。

      支持逗号合并写法（如 /a/b,c.js 解析为 /a/b.js 与 /a/c.js）。
      路径中含 ".." 或任一文件不存在时返回 null。

      Params:
          uri = 逻辑 URI（可含逗号表示多个文件）

      Returns:
          本地绝对路径数组，失败返回 null
  */
  string[] get(string uri) const {
    if (uri.indexOf("..") > -1)
      return null;
    auto files = resolve(uri);
    for (int i = 0; i < files.length; i++) {
      auto location = base ~ files[i];
      if (exists(location)) {
        files[i] = location;
      } else {
        logWarn("Cannot find %s", location);
        return null;
      }
    }
    return files;
  }

  /** 将“逗号合并”形式的 URI 拆成多个逻辑路径。

      例如 "/path/a,b.js" -> ["/path/a.js", "/path/b.js"]，无逗号则返回 [uri]。

      Params:
          uri = 可能含逗号的 URI

      Returns:
          拆分后的路径数组
  */
  static string[] resolve(string uri) {
    auto commaIdx = uri.indexOf(',');
    if (commaIdx > 0) {
      auto lastDotIdx = lastIndexOf(uri, '.');
      auto extension = uri[lastDotIdx .. $];
      string path = uri[0 .. commaIdx];
      auto lastSlashIdx = lastIndexOf(path, '/');
      path = path[0 .. lastSlashIdx + 1];
      string[] names = split(uri[(lastSlashIdx + 1) .. lastDotIdx], ',');
      for (int i = 0; i < names.length; i++) {
        names[i] = path ~ names[i] ~ extension;
      }
      return names;
    } else {
      return [uri];
    }
  }

  /** 根据全局配置构建静态资源仓库目录并返回仓库实例。

      会创建 base 目录，按 bundle 配置链接/下载 jar 并解压、挂载到对应路径，
      最后将根目录设为只读。

      Params:
          config = 包含 asset、maven 等配置的全局配置

      Returns:
          构建好的 AssetRepo 实例
  */
  static AssetRepo build(MicdnConfig config) {
    auto asset = config.asset;
    auto maven = config.maven;
    auto base = asset.base;
    if (exists(base)) {
      setWritable(base);
      //rmdirRecurse( base);
    }
    mkdirRecurse(base);
    logInfo("Building static resources at %s", base);
    foreach (c; asset.bundles) {
      auto bundlePath = "/" ~ c.name;
      foreach (p; c.providers) {
        if (DirProvider dp = cast(DirProvider) p) {
          auto bundleBase = base ~ "/" ~ c.name;
          if (exists(dp.location)) {
            if (exists(bundleBase)) {
              remove(bundleBase);
            }
            logInfo("Linking " ~ dp.location ~ " to " ~ bundleBase);
            makeSymlink(dp.location, bundleBase);
          } else {
            logWarn("Cannot link " ~ dp.location ~ " to " ~ bundleBase);
          }
        } else if (GavJarProvider gap = cast(GavJarProvider) p) {
          logInfo("Mounting %s", gap.gav);
          string local = maven.localFile(gap.gav);
          string innerDir = gap.dir;
          innerDir ~= bundlePath;
          if (exists(local)) {
            mount(base, local, bundlePath, innerDir);
          } else if (!local.endsWith("SNAPSHOT.jar")) {
            string[] remotes = maven.remoteUrls(gap.gav);
            mkdirRecurse(dirName(local));
            foreach (remote; remotes) {
              logInfo("Downloading %s", remote);
              import micdn.web.file;

              if (curlDownload(remote, local)) {
                mount(base, local, bundlePath, innerDir);
                break;
              }
            }
          } else {
            logWarn("Cannot resolve %s,ignore it.", gap.gav);
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
              auto docBase = base ~ bundlePath ~ "/" ~ versionPart;
              if (!extractTgzToDocBase(tgzPath, docBase, "package/" ~ np.dir)) {
                logWarn("Failed to extract %s to %s", tgzPath, docBase);
              }
            } else {
              logWarn("Cannot resolve npm package %s", np.packageSpec);
            }
          }
        } else if (ZipProvider zp = cast(ZipProvider) p) {
          logInfo("Mounting %s", zp.file);
          mount(base, zp.file, bundlePath, zp.dir);
        } else {
          //throw new R
        }
      }
    }
    setReadOnly(base);
    return new AssetRepo(base);
  }

  /** 将 zip/jar 中的指定子目录解压到仓库的 bundle 路径下。

      Params:
          base       = 仓库根目录
          zipfile   = zip/jar 文件路径
          bundlePath = bundle 在仓库中的路径（如 /bui）
          dir        = zip 内要解压的子目录（如 META-INF/resources）
  */
  private static void mount(string base, string zipfile, string bundlePath, string dir) {
    auto count = refreshUnzip(zipfile, base ~ bundlePath, dir);
    if (count == 0) {
      logWarn("Cannot find %s in %s", dir, zipfile);
    }
  }
}
