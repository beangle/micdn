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

module test.micdn.npm.prune_test;

import std.conv : to;
import std.file;
import std.json;
import std.path;
import std.random : unpredictableSeed;
import std.string;

import micdn.npm.packument : pruneDevVersions;

private string devVer(int i) {
  return "0.1.0-dev.2026010100000" ~ (cast(char)('0' + i)).to!string;
}

/// 在临时根下造 scoped 包：`base/@scope/name` 为 packument，版本目录 `base/scope/name/<ver>`。
private string makePackage(string root, string scopeName, string name, string[] versions, string[string] tags) {
  auto pkgDir = root ~ "/" ~ scopeName ~ "/" ~ name;
  JSONValue versionsJson = JSONValue.emptyObject;
  JSONValue timeJson = JSONValue.emptyObject;
  foreach (ver; versions) {
    mkdirRecurse(pkgDir ~ "/" ~ ver);
    write(pkgDir ~ "/" ~ ver ~ "/" ~ name ~ "-" ~ ver ~ ".tgz", "tgz-" ~ ver);
    JSONValue dist = JSONValue.emptyObject;
    dist["tarball"] = JSONValue("{origin}/npm/@" ~ scopeName ~ "/" ~ name ~ "/-/" ~ name ~ "-" ~ ver ~ ".tgz");
    dist["integrity"] = JSONValue("sha512-x");
    dist["shasum"] = JSONValue("x");
    JSONValue entry = JSONValue.emptyObject;
    entry["name"] = JSONValue("@" ~ scopeName ~ "/" ~ name);
    entry["version"] = JSONValue(ver);
    entry["dist"] = dist;
    versionsJson[ver] = entry;
    timeJson[ver] = JSONValue("2026-01-01T00:00:00.000Z");
  }
  JSONValue tagsJson = JSONValue.emptyObject;
  foreach (tag, ver; tags)
    tagsJson[tag] = JSONValue(ver);
  JSONValue doc = JSONValue.emptyObject;
  doc["name"] = JSONValue("@" ~ scopeName ~ "/" ~ name);
  doc["dist-tags"] = tagsJson;
  doc["versions"] = versionsJson;
  doc["time"] = timeJson;
  auto packument = root ~ "/@" ~ scopeName ~ "/" ~ name;
  mkdirRecurse(dirName(packument));
  std.file.write(packument, toJSON(doc, true) ~ "\n");
  return packument;
}

@("pruneDevVersions keeps newest N dev versions plus release and tagged versions")
unittest {
  auto root = tempDir() ~ "/micdn-npm-prune-" ~ to!string(unpredictableSeed());
  scope (exit)
    if (exists(root))
      rmdirRecurse(root);
  mkdirRecurse(root);

  auto all = ["0.1.0", devVer(1), devVer(2), devVer(3), devVer(4), devVer(5), devVer(6)];
  auto packument = makePackage(root, "beangle", "demo", all,
      ["latest": "0.1.0", "dev": devVer(6), "keepold": devVer(1)]);

  // dry-run 不动目录/文件
  auto dry = pruneDevVersions(root, 3, true);
  assert(dry.versionsRemoved == 1, to!string(dry.versionsRemoved));
  assert(exists(root ~ "/beangle/demo/" ~ devVer(2)));

  auto result = pruneDevVersions(root, 3, false);
  assert(result.packages == 1);
  assert(result.versionsRemoved == 1, to!string(result.versionsRemoved));
  assert(result.dirsRemoved == 1);

  // 保留：正式版 + 最新 3 个 dev（4/5/6） + tag 指向的 dev(1/6)
  assert(!exists(root ~ "/beangle/demo/" ~ devVer(2)));
  assert(exists(root ~ "/beangle/demo/" ~ devVer(3)));
  assert(exists(root ~ "/beangle/demo/" ~ devVer(1)));
  assert(exists(root ~ "/beangle/demo/" ~ devVer(4)));
  assert(exists(root ~ "/beangle/demo/" ~ devVer(6)));

  auto doc = parseJSON(readText(packument));
  assert(doc["versions"].object.length == 6, to!string(doc["versions"].object.length));
  assert(doc["dist-tags"]["latest"].str == "0.1.0");
  assert(doc["dist-tags"]["dev"].str == devVer(6));
  assert(doc["dist-tags"]["keepold"].str == devVer(1));
  assert(!(devVer(2) in doc["versions"].object));
}

@("pruneDevVersions never removes the only dev version and keeps dry-run clean")
unittest {
  auto root = tempDir() ~ "/micdn-npm-prune-keep1-" ~ to!string(unpredictableSeed());
  scope (exit)
    if (exists(root))
      rmdirRecurse(root);
  mkdirRecurse(root);

  makePackage(root, "beangle", "demo", ["0.1.0", devVer(1)], ["latest": "0.1.0", "dev": devVer(1)]);
  auto result = pruneDevVersions(root, 1, false);
  assert(result.versionsRemoved == 0);
  assert(exists(root ~ "/beangle/demo/" ~ devVer(1)));
}
