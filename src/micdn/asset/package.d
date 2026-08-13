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
/// 静态资源子模块：根据配置构建/刷新本地资源仓库，并按 URI 解析出命中结果（物理路径 + 文件信息）。

import std.algorithm;
import std.exception;
import std.file;
import std.path;
import std.string;
import std.datetime.stopwatch : StopWatch;

import vibe.core.log;
import vibe.core.file : FileInfo, getFileInfo;

import micdn.fs.index;
import micdn.fs.file;
import micdn.model;
import micdn.npm;
import micdn.web;
import micdn.web.gzip : precompressDir;

/// `AssetRepo.get` 命中结果：所属 bundle 名、物理路径、命中文件/目录的 `IndexedFileInfo`
/// （文件命中且存在 `path.gz` 时 `gzSize` 非 0；非 `<dir>` bundle 强制 gzip，索引同趟登记）
/// 与目录标志。未命中时 `path` 为 null。
struct AssetFile {
  string bundle; // 所属 bundle 名（URI 首段；供 `isDynaBundle` 等按 bundle 粒度判定，免重复解析 URI）
  string path;
  IndexedFileInfo info;
  bool isDir;
}

/// 静态资源仓库实例，持有本地根目录与目录列表开关，提供 URI 解析与文件路径查询。
class AssetRepo {
  /// 仓库根目录（绝对路径）。
  const string base;

  /// 构建阶段对 `<dir>` 成功 `makeSymlink` 的 bundle 名（动态内容、无 URL 版本段），供 `isDynaBundle` 与缓存策略使用（无需运行时读盘）。
  /// `null` 表示无任何 dyna bundle 登记（与空表等价）。
  const bool[string] dynaBundles;

  /// 非 `<dir>` bundle 的发布期文件索引（键为 bundle 名）：存在性与 gzip sidecar 查表（0 stat）。
  const FileIndex[string] bundleIndexes;

  /** 构造资源仓库实例。

      Params:
          base         = 仓库根目录
          dynaBundles = dyna bundle 名集合；`null` 表示未登记
          bundleIndexes = 非 `<dir>` bundle 的文件索引；`null` 表示未构建
  */
  this(string base, bool[string] dynaBundles = null, FileIndex[string] bundleIndexes = null) {
    enforce(base.length > 0, "repo base must not be empty");
    this.base = normalizeBasePath(base);
    this.dynaBundles = dynaBundles;
    this.bundleIndexes = bundleIndexes;
  }

  /** 非 `<dir>` bundle 的文件索引（按 bundle 名查；dyna 或未构建返回 null）。 */
  private const(FileIndex)* bundleIndexFor(string bundle) const {
    if (bundleIndexes is null)
      return null;
    return bundle in bundleIndexes;
  }

  /** bundle 名在 `dynaBundles` 中时为 true（`<dir>` 挂载），用于 HTTP 缓存策略。 */
  bool isDynaBundle(string bundle) const {
    if (dynaBundles is null)
      return false;
    return (bundle in dynaBundles) !is null;
  }

  /** 按逻辑 URI 解析并预取文件信息（类似 `WwwRepo.get`），不支持逗号拼接形式。

      非 `<dir>` bundle：发布期索引查询（存在性、目录分支与 gzip sidecar，0 stat）；
      `<dir>` bundle（dyna）：单次异步 stat。命中（文件或目录）时 `path` 非 null，
      文件命中且存在 `path.gz` 时 `info.gzSize` 为其大小；未命中时 `path` 为 null。
  */
  /** 便捷值重载：rvalue（如测试直构）走浅拷贝；生产路径（web 层持 lvalue）走 `ref` 版本。 */
  AssetFile get(const ResourceUri uri) const {
    return get(uri);
  }

  /** 按入口解析出的仓库 URI 解析并预取文件信息（仅供 web 服务层调用；**调用方负责防穿越**：须已由
      `getResourceUri` 切段消解，未消解的点段（`.`/`..`）可能导致 stat 兜底越界，属调用方违约）。
      首段为 bundle 名（索引根已含该层），其余段对齐 `{base}/{bundle}`。 */
  AssetFile get(ref const(ResourceUri) uri) const {
    auto bundle = uri.segs.length > 0 ? uri.segs[0] : "";
    if (auto idx = bundleIndexFor(bundle)) {
      auto hit = idx.find(uri.segs[1 .. $]);
      if (hit is null)
        return AssetFile.init;
      // 命中路径直接用索引根目录拼接（bundle 根固定，比 repositoryPath 省一次 base 前缀计算）
      auto rel = uri.segs[1 .. $];
      auto location = rel.length == 0 ? idx.rootDir : idx.rootDir ~ "/" ~ rel.join("/");
      return AssetFile(bundle, location, *hit, hit.isDirectory);
    }
    auto location = repositoryPath(base, uri);
    try {
      auto fi = getFileInfo(location);
      return AssetFile(bundle, location, IndexedFileInfo.fromFileInfo(fi), fi.isDirectory);
    } catch (Exception) {
      return AssetFile.init;
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
    FileIndex[string] indexes;
    size_t bundleCount, fileCount, dirCount, symlinkCount;
    StopWatch sw; // 仅累计索引构建耗时（部署期解压/下载不计入）
    logInfo("Building static resources at %s", base);
    foreach (c; config.asset.bundles) {
      deployBundle(config, c);
      bool dyna;
      foreach (p; c.providers) {
        if (DirProvider dp = cast(DirProvider) p) {
          auto bundleBase = base ~ "/" ~ c.name;
          if (exists(dp.location) && exists(bundleBase))
            dyna = true;
        }
      }
      if (dyna) {
        dynaBundles[c.name] = true;
      } else {
        auto bundleBase = base ~ "/" ~ c.name;
        if (exists(bundleBase)) {
          sw.start();
          auto idx = new FileIndex(bundleBase);
          sw.stop();
          indexes[c.name] = idx;
          bundleCount++;
          fileCount += idx.fileCount;
          dirCount += idx.dirCount;
          symlinkCount += idx.symlinkCount;
        }
      }
    }
    logInfo("Built asset bundle indexes: %s bundles, %s files, %s dirs%s in %s ms",
        bundleCount, fileCount, dirCount, symlinkSummaryPart(symlinkCount), sw.peek.total!"msecs");
    return new AssetRepo(base, dynaBundles.rehash(), indexes);
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
    // manifest 快路径判断须在解压前求值：解压成功会写入新 manifest，事后判断恒为“可跳过”。
    bool needDeploy = force || !canSkipDeploy(localJar, docBase, innerDir, gap.gav);
    bool deployed;
    if (exists(localJar)) {
      deployed = deployJar(localJar, docBase, innerDir, gap.gav, force);
    } else if (localJar.endsWith("SNAPSHOT.jar")) {
      logWarn("Cannot resolve %s, ignore it.", gap.gav);
      return false;
    } else {
      string[] remotes = maven.remoteUrls(gap.gav);
      mkdirRecurse(dirName(localJar));
      foreach (remote; remotes) {
        logInfo("Downloading %s", remote);
        import micdn.web.file;

        if (curlDownload(remote, localJar)) {
          deployed = deployJar(localJar, docBase, innerDir, gap.gav, force);
          break;
        }
      }
      if (!deployed) {
        logWarn("Cannot resolve %s", gap.gav);
        return false;
      }
    }
    // 非 `<dir>` bundle 强制启用 gzip：预压缩是实际解压部署的一环，manifest 快路径跳过解压时同样跳过
    //（已部署 bundle 再次启动不重复扫描；sidecar 已存在时 gzipFile 幂等跳过）。
    if (deployed && needDeploy)
      precompressDir(docBase);
    return deployed;
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
    // manifest 快路径判断须在解压前求值：解压成功会写入新 manifest，事后判断恒为“可跳过”。
    bool needDeploy = force || !canSkipDeploy(tgzPath, docBase, "package/" ~ np.dir, np.packageSpec);
    if (!extractTgzToDocBase(tgzPath, docBase, "package/" ~ np.dir, np.packageSpec, force)) {
      logWarn("Failed to extract %s to %s", tgzPath, docBase);
      return false;
    }
    // 非 `<dir>` bundle 强制启用 gzip：预压缩是实际解压部署的一环，manifest 快路径跳过解压时同样跳过。
    if (needDeploy)
      precompressDir(docBase);
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
