/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.web.cache;
/// 常用 HTTP 缓存策略；`CachePolicy` 作为值传给 `sendFile` / `sendFiles`；各域见 `*CachePolicy` 函数。

import std.datetime;
import std.path;
import std.string;

/**
 * `cacheControl` 为完整 `Cache-Control` 头；`maxAge` 与串中 `max-age=` 秒数一致（若有），供 vibe `handleCache` 写 `Expires` 等。
 * 不含 `max-age` 的策略（如 `no-cache` / `no-store`）对应 `maxAge == Duration.zero`。
 */
struct CachePolicy {
  string cacheControl;
  Duration maxAge;
}

// --- 基础策略（被下方函数与其它模块组合引用）---

/// `public, no-cache` — 可缓存，但每次使用前需校验。
immutable CachePolicy publicNoCache = CachePolicy("public, no-cache", Duration.zero);

/// `no-store` — 不缓存响应。
immutable CachePolicy noStore = CachePolicy("no-store", Duration.zero);

/// `public, max-age=604800` — 一周。
immutable CachePolicy publicMaxAge7d = CachePolicy("public, max-age=604800", 7.days);

/// `public, max-age=31536000, immutable` — 一年且声明不可变（指纹 URL / 版本路径等）。
immutable CachePolicy publicMaxAge1yImmutable = CachePolicy("public, max-age=31536000, immutable", 365.days);

// --- 按路径或域选择策略 ---

/**
 * Maven 仓库路径：`maven-metadata.xml`（及 `maven-metadata.xml.*`）→ `publicNoCache`；
 * `resolver-status.properties`、`*.lastUpdated` → `noStore`；路径含 `SNAPSHOT` 的构件 → `noStore`；
 * 其余 release 构件 → `publicMaxAge1yImmutable`。
 */
immutable(CachePolicy) mavenArtifactCachePolicy(string uri) {
  auto bn = baseName(uri);
  if (bn == "maven-metadata.xml" || bn.startsWith("maven-metadata.xml."))
    return publicNoCache;
  if (bn == "resolver-status.properties")
    return noStore;
  if (bn.endsWith(".lastUpdated"))
    return noStore;
  if (uri.indexOf("SNAPSHOT") >= 0)
    return noStore;
  return publicMaxAge1yImmutable;
}

/// npm 仓库：版本化 tarball 等，统一长期 `immutable`。
pragma(inline, true) immutable(CachePolicy) npmArtifactCachePolicy() { return publicMaxAge1yImmutable; }

/// 静态 `<bundle>`：`dynaBundles`（`<dir>` 挂载）→ `publicNoCache`；否则 jar/npm → `publicMaxAge1yImmutable`。
pragma(inline, true) immutable(CachePolicy) assetBundleCachePolicy(bool isDynaBundle) {
  return isDynaBundle ? publicNoCache : publicMaxAge1yImmutable;
}

/// blob GET：内容寻址，成功响应用 7 天公共缓存。
pragma(inline, true) immutable(CachePolicy) blobObjectCachePolicy() { return publicMaxAge7d; }

/**
 * WWW 静态文档：`*.html` → `publicNoCache`；其余 → `publicMaxAge7d`。
 */
immutable(CachePolicy) wwwDocCachePolicy(string path) {
  if (baseName(path).endsWith(".html"))
    return publicNoCache;
  return publicMaxAge7d;
}
