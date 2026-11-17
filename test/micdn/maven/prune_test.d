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

module test.micdn.maven.prune_test;

import std.conv : to;
import std.file;
import std.path : buildPath;
import std.random : unpredictableSeed;
import std.string;

import micdn.maven.gc : pruneSnapshotBuilds;

private string stamp(int i) {
  return "2026010" ~ i.to!string ~ ".01010" ~ i.to!string;
}

private void addBuild(string dir, string artifact, int i) {
  auto ts = stamp(i);
  auto base = dir ~ "/" ~ artifact ~ "-1.0-" ~ ts ~ "-" ~ i.to!string;
  write(base ~ ".jar", "jar");
  write(base ~ ".pom", "pom");
  write(base ~ ".jar.sha1", "sha1");
}

@("pruneSnapshotBuilds keeps newest N builds plus the one referenced by metadata")
unittest {
  auto root = tempDir() ~ "/micdn-maven-prune-" ~ to!string(unpredictableSeed());
  scope (exit)
    if (exists(root))
      rmdirRecurse(root);
  auto dir = root ~ "/org/demo/app/1.0-SNAPSHOT";
  mkdirRecurse(dir);
  foreach (i; 1 .. 5)
    addBuild(dir, "app", i);

  // 元数据指向最旧的构建 1：即使超出 keep 也要保留
  write(dir ~ "/maven-metadata.xml",
      "<?xml version=\"1.0\"?><metadata><versioning><snapshot>" ~
      "<timestamp>" ~ stamp(1) ~ "</timestamp><buildNumber>1</buildNumber>" ~
      "</snapshot></versioning></metadata>");

  auto dry = pruneSnapshotBuilds(root, 2, true);
  assert(dry.buildsRemoved == 1);
  assert(exists(dir ~ "/app-1.0-" ~ stamp(2) ~ "-2.jar"));

  auto result = pruneSnapshotBuilds(root, 2, false);
  assert(result.versions == 1);
  assert(result.buildsRemoved == 1, to!string(result.buildsRemoved));
  assert(result.filesRemoved == 3, to!string(result.filesRemoved));

  // 保留 1（元数据）、3、4；删除 2 的三件套
  assert(!exists(dir ~ "/app-1.0-" ~ stamp(2) ~ "-2.jar"));
  assert(!exists(dir ~ "/app-1.0-" ~ stamp(2) ~ "-2.pom"));
  assert(!exists(dir ~ "/app-1.0-" ~ stamp(2) ~ "-2.jar.sha1"));
  assert(exists(dir ~ "/app-1.0-" ~ stamp(1) ~ "-1.jar"));
  assert(exists(dir ~ "/app-1.0-" ~ stamp(3) ~ "-3.jar"));
  assert(exists(dir ~ "/app-1.0-" ~ stamp(4) ~ "-4.jar"));
}

@("pruneSnapshotBuilds always keeps at least one build")
unittest {
  auto root = tempDir() ~ "/micdn-maven-prune-keep1-" ~ to!string(unpredictableSeed());
  scope (exit)
    if (exists(root))
      rmdirRecurse(root);
  auto dir = root ~ "/org/demo/app/1.0-SNAPSHOT";
  mkdirRecurse(dir);
  foreach (i; 1 .. 4)
    addBuild(dir, "app", i);

  auto result = pruneSnapshotBuilds(root, 1, false);
  assert(result.buildsRemoved == 2, to!string(result.buildsRemoved));
  assert(exists(dir ~ "/app-1.0-" ~ stamp(3) ~ "-3.jar"));
  assert(!exists(dir ~ "/app-1.0-" ~ stamp(1) ~ "-1.jar"));
}
