/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.validate;
/// `micdn validate`：配置解析后的部署前提检查（目录可写、GAV、本地 artifact 等）。

import std.file;

import vibe.core.log;

import micdn.fs.file;
import micdn.model;
import micdn.npm;

/** 第二阶段校验：数据根可写，以及 www/static 引用的 dir/zip/jar/npm 是否就绪。

    XML 结构与属性合法性由 `parseFile` / `MicdnConfig` 构造完成（第一阶段）。
*/
bool validateMicdn(MicdnConfig config) {
  bool ok = true;

  bool checkRoot(string label, string dir) {
    if (verifyMountDirWritable(dir))
      return true;
    logError("Validate failed: %s base not writable: %s", label, dir);
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

  if (config.www !is null) {
    foreach (doc; config.www.docs) {
      auto ctx = "www doc " ~ doc.name;
      if (!validateProvider(config, ctx, doc.provider))
        ok = false;
      warnMissingTryFile(config, doc);
    }
  }

  if (config.asset !is null) {
    foreach (bundle; config.asset.bundles) {
      foreach (p; bundle.providers) {
        auto ctx = "static bundle " ~ bundle.name ~ " (" ~ p.path() ~ ")";
        if (!validateProvider(config, ctx, p))
          ok = false;
      }
    }
  }

  return ok;
}

private bool validateProvider(MicdnConfig config, string context, const(BundleProvider) provider) {
  if (DirProvider dp = cast(DirProvider) provider) {
    if (!exists(dp.location)) {
      logError("Validate %s failed: dir not found: %s", context, dp.location);
      return false;
    }
    return true;
  }
  if (ZipProvider zp = cast(ZipProvider) provider) {
    if (!exists(zp.file)) {
      logError("Validate %s failed: zip not found: %s", context, zp.file);
      return false;
    }
    if (!isZipFile(zp.file)) {
      logError("Validate %s failed: not a zip file: %s", context, zp.file);
      return false;
    }
    return true;
  }
  if (NpmProvider np = cast(NpmProvider) provider) {
    string scopePart, namePart, versionPart;
    parsePackageSpec(np.packageSpec, scopePart, namePart, versionPart);
    if (namePart.length == 0 || versionPart.length == 0) {
      logError("Validate %s failed: invalid npm spec: %s", context, np.packageSpec);
      return false;
    }
    auto tgzPath = NpmRepo.build(config).localTarball(scopePart, namePart, versionPart);
    if (!exists(tgzPath)) {
      logError("Validate %s failed: npm tarball missing: %s", context, tgzPath);
      return false;
    }
    return true;
  }
  if (GavJarProvider gap = cast(GavJarProvider) provider) {
    if (!isValidGav(gap.gav)) {
      logError("Validate %s failed: invalid gav: %s", context, gap.gav);
      return false;
    }
    auto localJar = config.maven.localFile(gap.gav);
    if (!exists(localJar)) {
      logError("Validate %s failed: jar missing: %s (%s)", context, gap.gav, localJar);
      return false;
    }
    if (!isZipFile(localJar)) {
      logError("Validate %s failed: not a jar/zip file: %s", context, localJar);
      return false;
    }
    return true;
  }
  logError("Validate %s failed: unsupported provider", context);
  return false;
}

private void warnMissingTryFile(MicdnConfig config, const WwwDocConfig doc) {
  if (doc.tryFile.length == 0)
    return;
  import micdn.web;

  auto path = resolveRepositoryPath(config.www.base, doc.endpoint() ~ "/" ~ doc.tryFile);
  if (path is null)
    return;
  if (!exists(path) || isDir(path))
    logWarn("Validate www doc %s: try-file %s not found at %s", doc.name, doc.tryFile, path);
}
