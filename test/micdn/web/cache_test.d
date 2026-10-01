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

import micdn.web.cache : noStore, publicMaxAge1yImmutable, publicNoCache, npmArtifactCachePolicy;

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
