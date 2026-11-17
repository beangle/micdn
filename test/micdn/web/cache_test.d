/* Copyright (C) 2026 Beangle
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

module test.micdn.web.cache_test;

import std.datetime : Duration, days;

import micdn.web.cache : gatedPolicy, noStore, publicMaxAge1yImmutable, publicMaxAge7d,
    publicNoCache, npmArtifactCachePolicy, wwwDocCachePolicy;

@("npmArtifactCachePolicy: release tarballs stay immutable in both uri forms")
unittest {
  // 官方 URL 形态：{pkg}/-/{name}-{version}.tgz
  assert(npmArtifactCachePolicy("/lodash/-/lodash-4.17.21.tgz") == publicMaxAge1yImmutable);
  assert(npmArtifactCachePolicy("/@xurp/manual/-/manual-0.0.2.tgz") == publicMaxAge1yImmutable);
  // 缓存目录形态：{scope|_}/{name}/{version}/{name}-{version}.tgz
  assert(npmArtifactCachePolicy("/_/lodash/4.17.21/lodash-4.17.21.tgz") == publicMaxAge1yImmutable);
  assert(npmArtifactCachePolicy("/xurp/manual/0.0.2/manual-0.0.2.tgz") == publicMaxAge1yImmutable);
  // 包名自带连字符/数字时取最后一个数字开头的段
  assert(npmArtifactCachePolicy("/jquery-ui/-/jquery-ui-1.13.2.tgz") == publicMaxAge1yImmutable);
}

@("npmArtifactCachePolicy: prereleases are revalidated, SNAPSHOTs are not stored")
unittest {
  assert(npmArtifactCachePolicy("/@xurp/manual/-/manual-0.0.3-dev.1.tgz") == publicNoCache);
  assert(npmArtifactCachePolicy("/lib/-/lib-2.0.0-rc.1.tgz") == publicNoCache);
  assert(npmArtifactCachePolicy("/_/lib/2.0.0-rc.1/lib-2.0.0-rc.1.tgz") == publicNoCache);
  assert(npmArtifactCachePolicy("/snap/-/snap-1.0.0-SNAPSHOT.tgz") == noStore);
  assert(npmArtifactCachePolicy("/_/snap/1.0.0-SNAPSHOT/snap-1.0.0-SNAPSHOT.tgz") == noStore);
}

@("npmArtifactCachePolicy: metadata, listings and non-tgz files are never immutable")
unittest {
  assert(npmArtifactCachePolicy("/@xurp/manual") == publicNoCache, "packument must revalidate");
  assert(npmArtifactCachePolicy("/lodash") == publicNoCache);
  assert(npmArtifactCachePolicy("/_/lodash/") == publicNoCache, "listing must revalidate");
  assert(npmArtifactCachePolicy("/") == publicNoCache);
  assert(npmArtifactCachePolicy("/_/lodash/4.17.21/notes.txt") == publicNoCache);
  assert(npmArtifactCachePolicy("/lodash/-/lodash-4.17.21.tgz.sha1") == publicNoCache,
      "sidecar without .tgz suffix must not inherit immutable");
  assert(npmArtifactCachePolicy("/_/lodash/4.17.21/lodash-notaversion.tgz") == publicNoCache,
      "unparseable version must not be treated as a release");
}

@("wwwDocCachePolicy: HTML and images revalidate, other www assets keep 7 days")
unittest {
  // www doc 每次 deploy 先清空再重新解压，同名图片可能被替换；给新鲜期会让浏览器在到期前
  // 不回源、继续用旧图，所以图片与 HTML 一样 no-cache，由 ETag / Last-Modified 在未变时回 304。
  foreach (path; ["/manual/index.html", "/manual/img/logo.png", "/manual/img/LOGO.PNG",
      "/manual/img/bg.jpg", "/manual/img/icon.svg", "/manual/img/photo.webp"])
    assert(wwwDocCachePolicy(path) == publicNoCache, path);
  // JS/CSS/字体等构建产物仍保留 7 天新鲜期
  foreach (path; ["/manual/app.js", "/manual/style.css", "/manual/font.woff2", "/manual/data.json"])
    assert(wwwDocCachePolicy(path) == publicMaxAge7d, path);
  assert(wwwDocCachePolicy("/manual/img/logo.png").maxAge == Duration.zero);
}

@("gatedPolicy downgrades public responses to private and keeps the rest")
unittest {
  // 受限响应只能进请求方自己的缓存：共享缓存按 URL 命中会把内容交给未授权者
  auto immutableGated = gatedPolicy(publicMaxAge1yImmutable);
  assert(immutableGated.cacheControl == "private, max-age=31536000, immutable");
  assert(immutableGated.maxAge == 365.days, "max-age 与 Expires 必须保持不变");
  assert(gatedPolicy(publicNoCache).cacheControl == "private, no-cache");
  assert(gatedPolicy(publicMaxAge7d).cacheControl == "private, max-age=604800");
  // 没有 public 前缀（no-store / no-cache）原样返回，未配置 download-key 时也无所谓
  assert(gatedPolicy(noStore) == noStore);
  assert(gatedPolicy(publicNoCache).maxAge == Duration.zero);
}
