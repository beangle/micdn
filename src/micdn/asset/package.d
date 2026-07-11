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

import std.algorithm;
import std.file;
import std.path;
import std.string;

import vibe.core.log;

import micdn.fs.file;
import micdn.model;
import micdn.npm;
import micdn.web;

/// 静态资源仓库实例，持有本地根目录与目录列表开关，提供 URI 解析与文件路径查询。
class AssetRepo {
  /// 仓库根目录（本地文件系统路径）。
  const string base;

  /// 构建阶段对 `<dir>` 成功 `makeSymlink` 的 bundle 名（动态内容、无 URL 版本段），供 `isDynaBundle` 与缓存策略使用（无需运行时读盘）。
  /// `null` 表示无任何 dyna bundle 登记（与空表等价）。
  const bool[string] dynaBundles;

  /** 构造资源仓库实例。

      Params:
          base         = 仓库根目录
          dynaBundles = dyna bundle 名集合；`null` 表示未登记
  */
  this(string base, bool[string] dynaBundles = null) {
    this.base = base;
    this.dynaBundles = dynaBundles;
  }

  /** 根据逻辑 URI 解析出对应的本地文件路径列表。

      支持逗号合并写法（如 /a/b,c.js 解析为 /a/b.js 与 /a/c.js）。
      路径经 URL 解码与规范化后须位于 `base` 下；任一文件不存在时返回 null。

      Params:
          uri = 逻辑 URI（可含逗号表示多个文件）

      Returns:
          本地绝对路径数组，失败返回 null
  */
  /** 从逻辑 URI 取首段 bundle 名（如 `/bui/0.6.7/x.js` → `bui`）。假定路径以 `/` 开头（`getPath` 语义）。 */
  static string bundleNameFromUri(string uri) {
    auto idx = uri.indexOf('/', 1);
    if (idx < 0)
      return uri[1 .. $];
    return uri[1 .. idx];
  }

  /** 首段 bundle 在 `dynaBundles` 中时为 true（`<dir>` 挂载），用于 HTTP 缓存策略。 */
  bool isDynaBundle(string uri) const {
    if (dynaBundles is null)
      return false;
    return (bundleNameFromUri(uri) in dynaBundles) !is null;
  }

  /** Params: uri = 已由 `getPath` 解码的相对路径。
  */
  string[] get(string uri) const {
    auto files = resolve(uri);
    string[] paths;
    paths.length = files.length;
    for (int i = 0; i < files.length; i++) {
      auto location = resolveRepositoryPath(base, files[i]);
      if (location is null || !exists(location))
        return null;
      paths[i] = location;
    }
    return paths;
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

  /** 确保 `asset.base` 存在且目录本身可写（见 `ensureDirWritable`，不递归子项）。 */
  static void prepareBase(string base) {
    mkdirRecurse(base);
    ensureDirWritable(base);
  }

  /** 根据全局配置构建静态资源仓库目录并返回仓库实例。

      创建 base 目录，按 bundle 配置链接/下载 jar 并解压、挂载。

      Params:
          config = 包含 asset、maven 等配置的全局配置

      Returns:
          构建好的 AssetRepo 实例
  */
  static AssetRepo build(MicdnConfig config) {
    auto base = config.asset.base;
    prepareBase(base);

    bool[string] dynaBundles;
    logInfo("Building static resources at %s", base);
    foreach (c; config.asset.bundles) {
      deployBundle(config, c);
      foreach (p; c.providers) {
        if (DirProvider dp = cast(DirProvider) p) {
          auto bundleBase = base ~ "/" ~ c.name;
          if (exists(dp.location) && exists(bundleBase))
            dynaBundles[c.name] = true;
        }
      }
    }
    return new AssetRepo(base, dynaBundles.rehash());
  }

  /** 将单个 static `<bundle>` 安装到 `asset.base` 下。供 `build` 与 `micdn … deploy static` 共用。
    成功返回 true，失败打日志并返回 false。
  */
  static bool deployBundle(MicdnConfig config, const AssetBundle bundle, bool force = false) {
    try {
      auto base = config.asset.base;
      auto bundlePath = "/" ~ bundle.name;
      auto bundleBase = base ~ "/" ~ bundle.name;
      mkdirRecurse(base);
      if (!verifyDeployDirWritable(base)) {
        logError("Deploy static %s failed: %s is not writable", bundle.name, base);
        return false;
      }

      bool ok = true;
      string[] allowedVersionDirs = [];
      foreach (p; bundle.providers) {
        if (DirProvider dp = cast(DirProvider) p) {
          if (!deployBundleDir(dp, bundleBase))
            ok = false;
        } else if (GavJarProvider gap = cast(GavJarProvider) p) {
          allowedVersionDirs ~= gap.getVersion();
          if (!deployBundleJar(config, bundlePath, gap, force))
            ok = false;
        } else if (NpmProvider np = cast(NpmProvider) p) {
          string scopePart, namePart, versionPart;
          parsePackageSpec(np.packageSpec, scopePart, namePart, versionPart);
          if (namePart.length == 0 || versionPart.length == 0) {
            logWarn("Invalid npm package spec: %s", np.packageSpec);
            ok = false;
          } else {
            allowedVersionDirs ~= versionPart;
            if (!deployBundleNpm(config, bundlePath, np, scopePart, namePart, versionPart, force))
              ok = false;
          }
        } else {
          logWarn("Unsupported static provider in bundle %s", bundle.name);
          ok = false;
        }
      }
      // 清理 bundle 下已从配置移除的 version 文件夹（仅当仅含 NpmProvider 时执行，jar 会创建 webjars 等顶层目录，不能误删）
      if (allowedVersionDirs.length > 0 && exists(bundleBase) && !bundleBase.isSymlink)
        cleanStaleVersionDirs(bundleBase, allowedVersionDirs);
      return ok;
    } catch (Exception e) {
      logError("Deploy static %s failed: %s", bundle.name, e.msg);
      return false;
    }
  }

  private static bool deployBundleDir(const DirProvider dp, string bundleBase) {
    if (!exists(dp.location)) {
      logWarn("Cannot link " ~ dp.location ~ " to " ~ bundleBase);
      return false;
    }
    if (exists(bundleBase))
      remove(bundleBase);
    logInfo("Linking " ~ dp.location ~ " to " ~ bundleBase);
    makeSymlink(dp.location, bundleBase);
    return true;
  }

  private static bool deployBundleJar(MicdnConfig config, const string bundlePath, const GavJarProvider gap,
      bool force) {
    auto base = config.asset.base;
    auto maven = config.maven;
    string localJar = maven.localFile(gap.gav);
    string innerDir = gap.dir ~ bundlePath ~ "/" ~ gap.getVersion();
    auto docBase = base ~ bundlePath ~ "/" ~ gap.getVersion();
    if (!verifyDeployDirWritable(docBase)) {
      logError("Deploy static %s failed: %s is not writable", gap.gav, docBase);
      return false;
    }
    if (exists(localJar))
      return deployJar(localJar, docBase, innerDir, gap.gav, force);
    if (localJar.endsWith("SNAPSHOT.jar")) {
      logWarn("Cannot resolve %s, ignore it.", gap.gav);
      return false;
    }
    string[] remotes = maven.remoteUrls(gap.gav);
    mkdirRecurse(dirName(localJar));
    foreach (remote; remotes) {
      logInfo("Downloading %s", remote);
      import micdn.web.file;

      if (curlDownload(remote, localJar))
        return deployJar(localJar, docBase, innerDir, gap.gav, force);
    }
    logWarn("Cannot resolve %s", gap.gav);
    return false;
  }

  private static bool deployBundleNpm(MicdnConfig config, const string bundlePath, const NpmProvider np,
      string scopePart, string namePart, string versionPart, bool force) {
    auto base = config.asset.base;
    auto npmRepo = NpmRepo.build(config);
    if (!npmRepo.fetch(scopePart, namePart, versionPart)) {
      logWarn("Cannot resolve npm package %s", np.packageSpec);
      return false;
    }
    auto tgzPath = npmRepo.localTarball(scopePart, namePart, versionPart);
    auto docBase = base ~ bundlePath ~ "/" ~ versionPart;
    if (!verifyDeployDirWritable(docBase)) {
      logError("Deploy static %s failed: %s is not writable", np.packageSpec, docBase);
      return false;
    }
    if (!extractTgzToDocBase(tgzPath, docBase, "package/" ~ np.dir, np.packageSpec, force)) {
      logWarn("Failed to extract %s to %s", tgzPath, docBase);
      return false;
    }
    return true;
  }

  /** 删除 bundle 目录下不在配置中的 version 子目录（仅 NpmProvider 会创建 version 顶层目录）。
     dirEntries 返回的 entry.name 是完整路径，需用 baseName 提取目录名再比较。
  */
  private static void cleanStaleVersionDirs(string bundleBase, const string[] allowedVersionDirs) {
    import std.algorithm;
    import std.path;

    foreach (entry; dirEntries(bundleBase, SpanMode.shallow, false)) {
      if (entry.isDir && !entry.isSymlink) {
        auto dirName = baseName(entry.name);
        if (!allowedVersionDirs.canFind(dirName)) {
          logInfo("Removing stale version dir: %s", entry.name);
          rmdirRecurse(entry.name);
        }
      }
    }
  }

  private static bool deployJar(string zipfile, string docBase, string dir, string artifact, bool force) {
    if (refreshUnzip(zipfile, docBase, dir, artifact, force) == 0) {
      logWarn("Cannot find %s in %s", dir, zipfile);
      return false;
    }
    return true;
  }
}
