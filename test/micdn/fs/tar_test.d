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

module test.micdn.fs.tar_test;

import micdn.fs.tar : extractTgz;

import std.file;
import std.path;
import std.conv : octal;
import std.array : replicate;
import std.uuid : randomUUID;

// ---- tgz 解压（内置 gzip + tar 解析）----

private string tarOctField(ulong v, size_t digits) {
  import std.format : format;
  import std.conv : to;
  auto s = to!string(v, 8);
  if (s.length > digits)
    s = s[$ - digits .. $];
  return "0".replicate(digits - s.length) ~ s;
}

private ubyte[] tarHeaderBlock(string name, const(ubyte)[] content, char type, int mode,
    string linkname = null) {
  import std.format : format;
  import std.algorithm : min;

  ubyte[512] hdr;
  void put(size_t off, size_t len, const(char)[] s) {
    auto n = min(len, s.length);
    hdr[off .. off + n] = cast(ubyte[]) s[0 .. n];
  }
  put(0, 100, name);
  put(100, 8, tarOctField(mode, 7) ~ "\0");
  put(108, 8, tarOctField(0, 7) ~ "\0");
  put(116, 8, tarOctField(0, 7) ~ "\0");
  put(124, 12, tarOctField(content.length, 11) ~ "\0");
  put(136, 12, tarOctField(0, 11) ~ "\0");
  hdr[156] = cast(ubyte) type;
  if (linkname !is null)
    put(157, 100, linkname);
  put(257, 6, "ustar\0");
  put(263, 2, "00");
  uint sum;
  foreach (i; 0 .. 512) {
    auto b = hdr[i];
    if (i >= 148 && i < 156)
      b = 0x20;
    sum += b;
  }
  put(148, 8, format("%06o", sum) ~ "\0 ");

  ubyte[] block;
  block ~= hdr[];
  block ~= content;
  auto pad = (512 - (content.length % 512)) % 512;
  block.length += pad;
  return block;
}

private ubyte[] tgzBytes(ubyte[][] entries...) {
  import std.zlib : Compress, HeaderFormat;

  ubyte[] tar;
  foreach (e; entries)
    tar ~= e;
  auto c = new Compress(9, HeaderFormat.gzip);
  ubyte[] gzOut;
  gzOut ~= cast(ubyte[]) c.compress(tar);
  gzOut ~= cast(ubyte[]) c.flush();
  return gzOut;
}

private string writeTgzFile(ubyte[] gz, string base) {
  mkdirRecurse(base);
  auto p = base ~ "/pkg.tgz";
  std.file.write(p, gz);
  return p;
}

@("extractTgz extracts files, dirs and preserves mode")
unittest {
  import std.conv : octal;

  auto base = tempDir() ~ "/micdn_tgz_basic_" ~ randomUUID().toString();
  scope (exit)
    if (exists(base))
      rmdirRecurse(base);

  auto gz = tgzBytes(
      tarHeaderBlock("package/", null, '5', octal!755),
      tarHeaderBlock("package/bin/run.sh", cast(ubyte[]) "hello\n", '0', octal!755),
      tarHeaderBlock("package/lib/data.txt", cast(ubyte[]) "data", '0', octal!644));
  auto tgz = writeTgzFile(gz, base);

  assert(extractTgz(tgz, base ~ "/out"), "extract should succeed");
  assert(exists(base ~ "/out/package/bin/run.sh"));
  assert(readText(base ~ "/out/package/bin/run.sh") == "hello\n");
  assert(readText(base ~ "/out/package/lib/data.txt") == "data");
  auto attrs = getAttributes(base ~ "/out/package/bin/run.sh");
  assert((attrs & octal!111) != 0, "executable bit should be preserved");
  auto dataAttrs = getAttributes(base ~ "/out/package/lib/data.txt");
  assert((dataAttrs & octal!111) == 0, "non-executable file should stay non-executable");
}

@("extractTgz handles symlink and hardlink")
unittest {
  auto base = tempDir() ~ "/micdn_tgz_link_" ~ randomUUID().toString();
  scope (exit)
    if (exists(base))
      rmdirRecurse(base);

  auto gz = tgzBytes(
      tarHeaderBlock("package/a.txt", cast(ubyte[]) "aaa", '0', octal!644),
      tarHeaderBlock("package/link.txt", null, '2', octal!777, "a.txt"),
      tarHeaderBlock("package/hard.txt", null, '1', octal!644, "package/a.txt"));
  auto tgz = writeTgzFile(gz, base);

  assert(extractTgz(tgz, base ~ "/out"), "extract should succeed");
  assert(readLink(base ~ "/out/package/link.txt") == "a.txt", "symlink target preserved verbatim");
  assert(readText(base ~ "/out/package/link.txt") == "aaa", "symlink should resolve");
  assert(readText(base ~ "/out/package/hard.txt") == "aaa", "hardlink should share content");
}

@("extractTgz handles GNU long names and pax path override")
unittest {
  auto base = tempDir() ~ "/micdn_tgz_long_" ~ randomUUID().toString();
  scope (exit)
    if (exists(base))
      rmdirRecurse(base);

  auto longName = "package/" ~ "dir_" ~ "a".replicate(90) ~ "/" ~ "f".replicate(30);
  auto nameBytes = cast(ubyte[]) (longName ~ "\0");
  auto gz = tgzBytes(
      tarHeaderBlock("LONGNAME", nameBytes, 'L', 0),
      tarHeaderBlock("dummy", cast(ubyte[]) "x", '0', octal!644),
      tarHeaderBlock("dummy", cast(ubyte[]) "20 path=package/sub\n", 'x', 0),
      tarHeaderBlock("dummy", cast(ubyte[]) "hello", '0', octal!644));
  auto tgz = writeTgzFile(gz, base);

  assert(extractTgz(tgz, base ~ "/out"), "extract should succeed");
  assert(readText(base ~ "/out/" ~ longName) == "x", "GNU long name should be extracted");
  assert(readText(base ~ "/out/package/sub") == "hello", "pax path override should apply");
}

@("extractTgz rejects traversal and non-gzip input")
unittest {
  auto base = tempDir() ~ "/micdn_tgz_bad_" ~ randomUUID().toString();
  scope (exit)
    if (exists(base))
      rmdirRecurse(base);

  auto gz = tgzBytes(tarHeaderBlock("../evil.txt", cast(ubyte[]) "x", '0', octal!644));
  auto tgz = writeTgzFile(gz, base);
  assert(!extractTgz(tgz, base ~ "/out"), "traversal entry must be rejected");

  auto plain = base ~ "/plain.tgz";
  std.file.write(plain, "not a gzip file");
  assert(!extractTgz(plain, base ~ "/out2"), "non-gzip must be rejected");
  assert(!extractTgz(base ~ "/missing.tgz", base ~ "/out3"), "missing file must fail");
}
