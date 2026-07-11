/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.resolve;
/// `micdn resolve`：解析配置、下载缺失 artifact、部署 www/static 并校验部署结果。

import std.file;
import std.path : buildPath;

import vibe.core.log;

import micdn.asset;
import micdn.fs.file;
import micdn.model;
import micdn.npm;
import micdn.web;
import micdn.www;

/** 解析并安装部署前提：数据根可写，www/static 下载（如需）并 deploy，校验部署目录。

    XML 结构与属性合法性由 `parseFile` / `MicdnConfig` 构造完成（第一阶段）。
*/
bool resolveMicdn(MicdnConfig config) {
  bool ok = true;

  if (!checkServiceRoots(config))
    ok = false;

  if (config.www !is null) {
    WwwRepo.prepareBase(config.www.base);
    foreach (doc; config.www.docs) {
      if (!resolveWwwDoc(config, doc))
        ok = false;
    }
  }

  if (config.asset !is null) {
    AssetRepo.prepareBase(config.asset.base);
    foreach (bundle; config.asset.bundles) {
      if (!resolveStaticBundle(config, bundle))
        ok = false;
    }
  }

  return ok;
}

private bool checkServiceRoots(MicdnConfig config) {
  bool ok = true;

  bool checkRoot(string label, string dir) {
    if (verifyDeployDirWritable(dir))
      return true;
    logError("Resolve failed: %s base not writable: %s", label, dir);
    return false;
  }

  if (!checkRoot("maven", config.maven.base))
    ok = false;
  if (!checkRoot("npm", config.npm.base))
    ok = false;
  if (config.asset !is null && !checkRoot("static", config.asset.base))
    ok = false;
  if (config.www !is null && !checkRoot("www", config.www.base))
    ok = false;
  if (config.blob !is null && !checkRoot("blob", config.blob.base))
    ok = false;
  return ok;
}

private bool resolveWwwDoc(MicdnConfig config, const WwwDocConfig doc) {
  auto ctx = "www doc " ~ doc.name;
  if (!validateProviderSpec(config, ctx, doc.provider))
    return false;
  if (!WwwRepo.deployDoc(config, doc, false)) {
    logError("Resolve %s failed: deploy", ctx);
    return false;
  }
  if (!verifyWwwDocDeployed(config, doc))
    return false;
  warnMissingTryFile(config, doc);
  return true;
}

private bool resolveStaticBundle(MicdnConfig config, const AssetBundle bundle) {
  foreach (p; bundle.providers) {
    auto ctx = "static bundle " ~ bundle.name ~ " (" ~ p.path() ~ ")";
    if (!validateProviderSpec(config, ctx, p))
      return false;
  }
  if (!AssetRepo.deployBundle(config, bundle, false)) {
    logError("Resolve static bundle %s failed: deploy", bundle.name);
    return false;
  }
  return verifyStaticBundleDeployed(config, bundle);
}

private bool validateProviderSpec(MicdnConfig config, string context, const(BundleProvider) provider) {
  if (DirProvider dp = cast(DirProvider) provider) {
    if (!exists(dp.location)) {
      logError("Resolve %s failed: dir not found: %s", context, dp.location);
      return false;
    }
    return true;
  }
  if (ZipProvider zp = cast(ZipProvider) provider) {
    if (!exists(zp.file)) {
      logError("Resolve %s failed: zip not found: %s", context, zp.file);
      return false;
    }
    if (!isZipFile(zp.file)) {
      logError("Resolve %s failed: not a zip file: %s", context, zp.file);
      return false;
    }
    return true;
  }
  if (NpmProvider np = cast(NpmProvider) provider) {
    string scopePart, namePart, versionPart;
    parsePackageSpec(np.packageSpec, scopePart, namePart, versionPart);
    if (namePart.length == 0 || versionPart.length == 0) {
      logError("Resolve %s failed: invalid npm spec: %s", context, np.packageSpec);
      return false;
    }
    return true;
  }
  if (GavJarProvider gap = cast(GavJarProvider) provider) {
    if (!isValidGav(gap.gav)) {
      logError("Resolve %s failed: invalid gav: %s", context, gap.gav);
      return false;
    }
    return true;
  }
  logError("Resolve %s failed: unsupported provider", context);
  return false;
}

private bool verifyWwwDocDeployed(MicdnConfig config, const WwwDocConfig doc) {
  auto ctx = "www doc " ~ doc.name;
  auto docDir = resolveRepositoryPath(config.www.base, doc.endpoint());
  if (docDir is null) {
    logError("Resolve %s failed: path escapes base", ctx);
    return false;
  }
  if (DirProvider dp = cast(DirProvider) doc.provider) {
    if (!exists(docDir)) {
      logError("Resolve %s failed: symlink missing: %s", ctx, docDir);
      return false;
    }
    return true;
  }
  if (ZipProvider zp = cast(ZipProvider) doc.provider) {
    if (!verifyDeployedDocBase(ctx, docDir, zp.dir))
      return false;
    return true;
  }
  if (NpmProvider np = cast(NpmProvider) doc.provider) {
    if (!verifyDeployedDocBase(ctx, docDir, np.dir))
      return false;
    return true;
  }
  return false;
}

private bool verifyStaticBundleDeployed(MicdnConfig config, const AssetBundle bundle) {
  auto base = config.asset.base;
  auto bundlePath = "/" ~ bundle.name;
  bool ok = true;
  foreach (p; bundle.providers) {
    auto ctx = "static bundle " ~ bundle.name ~ " (" ~ p.path() ~ ")";
    if (DirProvider dp = cast(DirProvider) p) {
      auto bundleBase = base ~ bundlePath;
      if (!exists(bundleBase)) {
        logError("Resolve %s failed: symlink missing: %s", ctx, bundleBase);
        ok = false;
      }
    } else if (GavJarProvider gap = cast(GavJarProvider) p) {
      auto docBase = base ~ bundlePath ~ "/" ~ gap.getVersion();
      if (!verifyDeployedDocBase(ctx, docBase, gap.dir))
        ok = false;
    } else if (NpmProvider np = cast(NpmProvider) p) {
      string scopePart, namePart, versionPart;
      parsePackageSpec(np.packageSpec, scopePart, namePart, versionPart);
      auto docBase = base ~ bundlePath ~ "/" ~ versionPart;
      if (!verifyDeployedDocBase(ctx, docBase, np.dir))
        ok = false;
    }
  }
  return ok;
}

/** 部署完成后确认 docBase 存在且非空；npm/zip 的 `dir` 在 deploy 阶段已校验，此处再确认产物目录。 */
private bool verifyDeployedDocBase(string context, string docBase, string innerDir) {
  if (docBase is null || !exists(docBase) || !isDir(docBase)) {
    logError("Resolve %s failed: deploy dir missing: %s", context, docBase);
    return false;
  }
  if (dirEntryCount(docBase) == 0) {
    logError("Resolve %s failed: deploy dir empty: %s", context, docBase);
    return false;
  }
  if (innerDir.length > 0)
    logInfo("Resolve %s ok: inner dir %s -> %s", context, innerDir, docBase);
  return true;
}

private size_t dirEntryCount(string dir) {
  import std.file : dirEntries, SpanMode;

  size_t n;
  foreach (_; dirEntries(dir, SpanMode.shallow))
    n++;
  return n;
}

private void warnMissingTryFile(MicdnConfig config, const WwwDocConfig doc) {
  if (doc.tryFile.length == 0)
    return;
  auto path = resolveRepositoryPath(config.www.base, doc.endpoint() ~ "/" ~ doc.tryFile);
  if (path is null)
    return;
  if (!exists(path) || isDir(path))
    logWarn("Resolve www doc %s: try-file %s not found at %s", doc.name, doc.tryFile, path);
}
