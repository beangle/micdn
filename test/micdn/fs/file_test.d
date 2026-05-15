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

module test.micdn.fs.file_test;

import micdn.fs.file;

import std.file;
import std.path;
import std.stdio;
import std.uuid : randomUUID;
import std.zip;

@("makeSymlink stores absolute path for relative and tilde")
unittest {
  auto base = tempDir() ~ "micdn_symlink_test";
  scope (exit) {
    if (exists(base))
      rmdirRecurse(base);
  }
  auto targetDir = base ~ "/target";
  auto linkPath = base ~ "/link";
  mkdirRecurse(targetDir);
  std.file.write(targetDir ~ "/f", "x");

  auto cwd = getcwd();
  scope (exit)
    chdir(cwd);
  chdir(base);
  makeSymlink("target", linkPath);
  chdir(cwd);

  assert(exists(linkPath), "symlink should exist");
  auto stored = readLink(linkPath);
  assert(isAbsolute(stored), "symlink target should be absolute, got: " ~ stored);
  assert(exists(linkPath ~ "/f"), "content should be reachable via symlink");
  remove(linkPath);

  makeSymlink("~", linkPath);
  stored = readLink(linkPath);
  assert(isAbsolute(stored), "tilde path should expand to absolute, got: " ~ stored);
  remove(linkPath);
}

@("refreshUnzip overwrites when size matches but content differs")
unittest {
  import std.file : exists, mkdirRecurse, rmdirRecurse, write;

  string tmp = buildPath(tempDir(), "micdn-refresh-unzip-" ~ randomUUID().toString);
  mkdirRecurse(tmp);
  scope (exit) {
    if (exists(tmp))
      rmdirRecurse(tmp);
  }

  void writeZip(string path, ubyte[] content) {
    auto m = new ArchiveMember();
    m.name = "x.txt";
    m.expandedData(content);
    ZipArchive z = new ZipArchive();
    z.addMember(m);
    write(path, z.build());
  }

  string zip1 = buildPath(tmp, "1.zip");
  string zip2 = buildPath(tmp, "2.zip");
  string base = buildPath(tmp, "out");

  writeZip(zip1, cast(ubyte[]) "AAAAA");
  writeZip(zip2, cast(ubyte[]) "BBBBB");
  refreshUnzip(zip1, base, null);
  assert(readText(buildPath(base, "x.txt")) == "AAAAA");
  refreshUnzip(zip2, base, null);
  assert(readText(buildPath(base, "x.txt")) == "BBBBB");
}

@("fs unzip and permissions")
unittest {
  import std.file : read;
  import std.stdio;

  auto zipPath = "/tmp/beangle-bundles-bui-0.2.1.jar";
  if (exists(zipPath)) {
    auto base = "/tmp/beangle-bundles-bui-0.2.1";
    unzip(zipPath, base, "META-INF/resources/bui");
    setReadOnly(base);
    setWritable(base);
    base.rmdirRecurse();
  }
}
