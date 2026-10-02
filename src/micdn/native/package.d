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

module micdn.native;
/** 本地 native 发行包仓库：native-image 产物（tar.gz）、增量补丁（.diff）及其校验文件。

    **单根**：所有版本都放在 `<native base>` 下，按 maven 布局归档
    `{group 点转斜杠}/{artifact}/{version}/{文件名}`。不再像 sashub 那样按
    `~/.m2/repository` / `~/.m2/snapshots` 分两个根——版本目录名里的 `-SNAPSHOT` 已经能区分，
    与 `/maven`「正式版与 SNAPSHOT 共用一个 base」同口径（见 `docs/merged_repo.md`）。

    与 maven 侧的区别：native 构件**没有任何元数据**（没有 pom、没有 maven-metadata.xml），
    坐标完全由路径决定；发行包文件名不带时间戳（开发版同名覆盖），只有增量补丁带时间戳。
    因此「不带时间戳的补丁名 → 最新构建」只能按文件名里 `-SNAPSHOT` 的位置做目录扫描
    （`latestAlias`），套不上 maven 那套 `maven-metadata.xml` 规则。

    HTTP 侧见 `micdn.native.web.NativeService`。
*/

import std.algorithm : endsWith, startsWith;
import std.conv : to;
import std.file;
import std.path : baseName, dirName;
import std.string : lastIndexOf;

import micdn.model;
import micdn.web : normalizeBasePath;

/// 版本标记：版本目录名与补丁别名都靠它定位「时间戳插在哪里」。
private enum string snapshotMark = "-SNAPSHOT";
/// 时间戳本身的长度（`yyyyMMdd.HHmmss`）。
private enum size_t stampLength = 15;

/** native 仓库：单根布局 + 「不带时间戳的别名 → 最新时间戳文件」解析。

    - 构件由客户端经 `/native` 的 PUT 发布（或运维按目录规范放入）；
    - 与 `SnapshotRepo` 一样只负责本地布局，不做上游代理（迁移期可先由运维同步旧仓库）。
*/
class NativeRepo {
  /// 仓库根目录（绝对路径）
  const string base;

  this(string base) {
    import std.exception : enforce;

    enforce(base.length > 0, "native base must not be empty");
    this.base = normalizeBasePath(base);
  }

  static NativeRepo build(MicdnConfig config) {
    mkdirRecurse(config.native.base);
    return new NativeRepo(config.native.base);
  }

  /// 仓库内相对 uri（以 `/` 开头）→ 绝对路径。
  string fileOf(string ruri) const {
    return base ~ ruri;
  }

  /** 「不带时间戳的别名」→ 同目录最新的时间戳文件（返回相对 uri，无候选则 null）。

      与 maven 的 `SnapshotRepo.latestAlias` 不同：native 的文件名里时间戳插在**最后一个**
      `-SNAPSHOT` 之后，而不是紧跟版本号——增量补丁名为
      `{artifact}-{基准版本}_{版本}[-{时间戳}-{构建号}]-{classifier}.tar.gz.diff`，
      时间戳前面还有基准版本。所以这里以最后一个 `-SNAPSHOT` 为锚点切出前缀/后缀，
      要求中间形如 `yyyyMMdd.HHmmss-N`（`NativeHelper.TimestampPattern` 同口径）。

      发行包（`...-SNAPSHOT-linux-amd64.tar.gz`）没有时间戳、不存在候选，返回 null，
      由调用方按普通文件直接取；`.sha1` 别名用同一规则匹配带 `.sha1` 的同名文件。
      取时间戳与构建号最大者（构建号是多位数字，必须按数字比，不能按字典序）。
  */
  string latestAlias(string ruri) const {
    auto name = baseName(ruri);
    auto anchor = name.lastIndexOf(snapshotMark);
    if (anchor < 0)
      return null;
    auto dir = dirName(ruri);
    auto dirPath = base ~ dir;
    if (!exists(dirPath) || !isDir(dirPath))
      return null;

    auto prefix = name[0 .. anchor + snapshotMark.length] ~ "-";
    auto suffix = name[anchor + snapshotMark.length .. $];
    string best, bestStamp;
    foreach (entry; dirEntries(dirPath, SpanMode.shallow)) {
      if (entry.isDir)
        continue;
      auto candidate = baseName(entry.name);
      if (candidate.length <= prefix.length + suffix.length)
        continue;
      if (!candidate.startsWith(prefix) || !candidate.endsWith(suffix))
        continue;
      auto stamp = candidate[prefix.length .. candidate.length - suffix.length];
      if (!isStamp(stamp))
        continue;
      if (best.length == 0 || compareStamp(bestStamp, stamp) < 0) {
        best = candidate;
        bestStamp = stamp;
      }
    }
    return best.length > 0 ? dir ~ "/" ~ best : null;
  }
}

/// 是否形如 `yyyyMMdd.HHmmss-N`（N 为一位以上的构建号）。
private bool isStamp(string s) {
  if (s.length < stampLength + 2)
    return false;
  foreach (i; 0 .. 8)
    if (!isDigit(s[i]))
      return false;
  if (s[8] != '.')
    return false;
  foreach (i; 9 .. stampLength)
    if (!isDigit(s[i]))
      return false;
  if (s[stampLength] != '-')
    return false;
  // 构建号限制在 int 范围内：越界的「时间戳」不是本仓库的命名，直接不算候选，
  // 免得 compareStamp 在 to!int 上抛异常把请求变成 500（可正常按普通文件下载）。
  if (s.length - stampLength - 1 > 9)
    return false;
  foreach (i; stampLength + 1 .. s.length)
    if (!isDigit(s[i]))
      return false;
  return true;
}

private bool isDigit(char c) {
  return c >= '0' && c <= '9';
}

/// 先比定长时间戳串，再比构建号数值：`...-9` 早于 `...-10`。
private int compareStamp(string a, string b) {
  if (a[0 .. stampLength] < b[0 .. stampLength])
    return -1;
  if (a[0 .. stampLength] > b[0 .. stampLength])
    return 1;
  auto left = to!int(a[stampLength + 1 .. $]);
  auto right = to!int(b[stampLength + 1 .. $]);
  return left < right ? -1 : (left > right ? 1 : 0);
}
