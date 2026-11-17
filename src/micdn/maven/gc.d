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

module micdn.maven.gc;
/// 本地 Maven SNAPSHOT 构建清理：每个 `*-SNAPSHOT` 版本目录按时间戳保留最新 N 个构建。
///
/// 同一版本目录里，`mvn deploy` 每次都是新时间戳的一组文件（jar/pom/sha1…），长期会累积。
/// 清理按「时间戳 + buildNumber」成组删除，版本级 `maven-metadata.xml` 指向的构建与最新 N 个
/// 构建一律保留（至少保留 1 个）；artifact 级 `maven-metadata.xml`（版本列表）不在这里改。

import std.algorithm : sort;
import std.array : array;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, isDir, readText, remove;
import std.path : baseName, dirName;
import std.string : endsWith, indexOf, startsWith, strip;

import vibe.core.log;

import micdn.maven.snapshot : SnapshotFile, metadataFileName, parseSnapshotName;
import micdn.web : normalizeBasePath;

/// 清理结果（CLI / 管理端点打印用）。
struct MavenPruneResult {
  /// 扫描到的 `*-SNAPSHOT` 版本目录数
  size_t versions;
  /// 删除的构建组数
  size_t buildsRemoved;
  /// 删除的文件数
  size_t filesRemoved;
  /// 删除的 `artifact:version timestamp-build` 清单
  string[] removed;
}

/** 清理 `base` 下所有 `*-SNAPSHOT` 版本目录：每个目录保留最新 `keep` 个构建
    （`keep` 至少 1），外加版本级 `maven-metadata.xml` 指向的构建；`dryRun` 只统计。 */
MavenPruneResult pruneSnapshotBuilds(string base, uint keep = 1, bool dryRun = false) {
  MavenPruneResult result;
  if (keep < 1)
    keep = 1;
  auto root = normalizeBasePath(base);
  if (!exists(root) || !isDir(root))
    return result;
  visit(root, keep, dryRun, result);
  return result;
}

private void visit(string dir, uint keep, bool dryRun, ref MavenPruneResult result) {
  foreach (entry; dirEntries(dir, SpanMode.shallow, false)) {
    if (!entry.isDir || entry.isSymlink)
      continue;
    auto name = baseName(entry.name);
    if (name.endsWith("-SNAPSHOT")) {
      result.versions++;
      pruneVersionDir(entry.name, keep, dryRun, result);
    } else {
      visit(entry.name, keep, dryRun, result);
    }
  }
}

/// 一个版本目录：按 build 分组，保留最新 keep 个与元数据指向的 build。
private void pruneVersionDir(string dir, uint keep, bool dryRun, ref MavenPruneResult result) {
  auto artifact = baseName(dirName(dir));
  auto ver = baseName(dir);
  auto protectedKey = metadataBuildKey(dir);

  BuildKey[string] groups;
  string[][string] filesOfGroup;
  foreach (entry; dirEntries(dir, SpanMode.shallow, false)) {
    if (entry.isDir || entry.isSymlink)
      continue;
    auto name = baseName(entry.name);
    if (name == metadataFileName || name.startsWith(metadataFileName ~ "."))
      continue;
    SnapshotFile parsed;
    if (!parseSnapshotName(coreName(name), artifact, ver, parsed))
      continue;
    auto key = buildKey(parsed);
    groups[key.text] = key;
    filesOfGroup[key.text] ~= entry.name;
  }
  if (groups.length <= keep)
    return;

  BuildKey[] keys = groups.values;
  keys.sort!((a, b) => compareBuild(a, b) < 0); // 升序：旧 → 新

  auto kept = keep > keys.length ? keys.length : keep;
  bool[string] keepSet;
  foreach (i; 0 .. kept)
    keepSet[keys[keys.length - 1 - i].text] = true;
  if (protectedKey.length > 0)
    keepSet[protectedKey] = true;

  foreach (key; keys) {
    if (key.text in keepSet)
      continue;
    foreach (file; filesOfGroup[key.text]) {
      if (!dryRun)
        remove(file);
      result.filesRemoved++;
    }
    result.buildsRemoved++;
    result.removed ~= artifact ~ ":" ~ ver ~ " " ~ key.text;
  }
}

/// 版本级元数据里的 `<snapshot><timestamp>` + `<buildNumber>` 组合；读不到返回空串。
private string metadataBuildKey(string dir) {
  auto file = dir ~ "/" ~ metadataFileName;
  if (!exists(file))
    return "";
  string text;
  try
    text = readText(file);
  catch (Exception)
    return "";
  auto ts = tagText(text, "timestamp");
  auto build = tagText(text, "buildNumber");
  if (ts.length == 0 || build.length == 0)
    return "";
  return ts ~ "-" ~ build;
}

/// 取 `<tag>…</tag>` 的文本（第一个匹配）。
private string tagText(string text, string tag) {
  auto open = "<" ~ tag ~ ">";
  auto close = "</" ~ tag ~ ">";
  auto i = text.indexOf(open);
  if (i < 0)
    return "";
  i += open.length;
  auto j = text.indexOf(close, i);
  return j < 0 ? "" : text[i .. j].strip;
}

private string coreName(string name) {
  foreach (suffix; [".sha1", ".md5"])
    if (name.endsWith(suffix))
      return name[0 .. $ - suffix.length];
  return name;
}

private BuildKey buildKey(const ref SnapshotFile parsed) {
  return BuildKey(parsed.timestamp, parsed.build, parsed.timestamp ~ "-" ~ parsed.build.to!string);
}

private struct BuildKey {
  string timestamp;
  int build;
  string text;
}

/// 先比 15 位定长时间戳，再比 buildNumber 数值。
private int compareBuild(const ref BuildKey a, const ref BuildKey b) {
  if (a.timestamp != b.timestamp)
    return a.timestamp < b.timestamp ? -1 : 1;
  return a.build < b.build ? -1 : (a.build > b.build ? 1 : 0);
}
