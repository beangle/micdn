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

module micdn.asset_test;

import micdn.asset;
import micdn.config;
import micdn.model;
import micdn.web;
import micdn.fs.index : FileIndex;
import micdn.web.gzip : gzipFile;
import micdn.xml;
import std.file;
import std.path;

/// 测试辅助：uri 字符串 → `ResourceUri`（模拟入口 `getResourceUri` 的语义）。
private ResourceUri segsOf(string uri) {
  return segmentPath(uri);
}

@("asset dynaBundles registry for cache policy")
unittest {
  bool[string] reg;
  reg["mine"] = true;
  auto repo = new AssetRepo("/base", reg.rehash());
  assert(repo.isDynaBundle("mine"));
  assert(!repo.isDynaBundle("jarbundle"));
  assert(!repo.isDynaBundle(""));
}

@("asset get resolves files and entry rejects traversal")
unittest {
  auto tmp = absolutePath(buildPath(tempDir, "micdn-asset-safe"));
  auto outside = buildPath(tempDir, "micdn-asset-outside.txt");
  scope (exit) {
    if (exists(tmp))
      rmdirRecurse(tmp);
    if (exists(outside))
      remove(outside);
  }
  mkdirRecurse(buildPath(tmp, "bui", "0.1"));
  write(buildPath(tmp, "bui", "0.1", "a.js"), "x");
  write(outside, "outside");

  auto repo = new AssetRepo(tmp);
  auto good = repo.get(segsOf("/bui/0.1/a.js"));
  assert(good.path == repositoryPath(tmp, segsOf("/bui/0.1/a.js")));
  assert(good.info.isFile());
  // 编码穿越在入口 `getResourceUri`/`segmentPath` 拒绝
  assert(!segmentPath(decodeRepositoryUri("/%2e%2e%2f" ~ baseName(outside))).ok);
  assert(decodeRepositoryUri("/%5cWindows%5cwin.ini") is null);
}

@("asset get ref overload matches value overload")
unittest {
  auto tmp = absolutePath(buildPath(tempDir, "micdn-asset-refval"));
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "bui", "0.1"));
  write(buildPath(tmp, "bui", "0.1", "a.js"), "x");

  auto repo = new AssetRepo(tmp);
  auto uri = segsOf("/bui/0.1/a.js");
  auto viaRef = repo.get(uri); // lvalue：走 ref 重载
  auto viaVal = repo.get(segsOf("/bui/0.1/a.js")); // rvalue：走值重载
  assert(viaRef.path == viaVal.path);
  assert(viaRef.info.isFile());
  assert(viaRef.info.size == viaVal.info.size);
}

@("asset get resolves via bundle index with gzSize")
unittest {
  auto tmp = absolutePath(buildPath(tempDir, "micdn-asset-index"));
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "bui", "0.1"));
  string content;
  foreach (i; 0 .. 200)
    content ~= "var k = 1; console.log('x');\n";
  auto jsPath = buildPath(tmp, "bui", "0.1", "a.js");
  write(jsPath, content);
  assert(gzipFile(jsPath), "non-dir bundles precompress at deploy time");

  FileIndex[string] indexes;
  indexes["bui"] = new FileIndex(buildPath(tmp, "bui"));
  auto repo = new AssetRepo(tmp, null, indexes);

  auto rs = repo.get(segsOf("/bui/0.1/a.js"));
  assert(rs.bundle == "bui", "hit must carry its bundle name");
  assert(rs.path == repositoryPath(tmp, segsOf("/bui/0.1/a.js")));
  assert(rs.info.isFile());
  assert(rs.info.gzSize == getSize(jsPath ~ ".gz"), "index must attach the sidecar size");
  assert(!rs.isDir);
  assert(repo.get(segsOf("/bui/0.1/missing.js")).path is null);
  assert(repo.get(segsOf("/bui/0.1")).isDir, "bundle subdir must resolve as directory");
  assert(repo.get(segsOf("/bui")).isDir, "bundle root must resolve as directory");
}

@("asset index semantics: sidecar gzSize, no gz nodes, dirs, stale path")
unittest {
  auto tmp = absolutePath(buildPath(tempDir, "micdn-asset-index-sem"));
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "bui", "0.1"));
  string bigContent;
  foreach (i; 0 .. 200)
    bigContent ~= "var k = 1; console.log('x');\n";
  auto bigPath = buildPath(tmp, "bui", "0.1", "big.js");
  write(bigPath, bigContent);
  assert(gzipFile(bigPath));
  // 小于压缩下限的文件部署期不会生成 sidecar
  write(buildPath(tmp, "bui", "0.1", "small.js"), "var s=1;");

  FileIndex[string] indexes;
  indexes["bui"] = new FileIndex(buildPath(tmp, "bui"));
  auto repo = new AssetRepo(tmp, null, indexes);

  auto big = repo.get(segsOf("/bui/0.1/big.js"));
  assert(big.info.isFile());
  assert(big.info.gzSize == getSize(bigPath ~ ".gz"), "index must attach the sidecar size");
  assert(repo.get(segsOf("/bui/0.1/small.js")).info.gzSize == 0, "no sidecar => gzSize 0");
  assert(repo.get(segsOf("/bui/0.1/big.js.gz")).path is null, ".gz must not be indexed as content");
  assert(repo.get(segsOf("/bui/0.1")).isDir);
  assert(repo.get(segsOf("/bui")).isDir);

  // 索引 0 stat：命中后不复查磁盘；文件被删仍返回 path（读盘失败由 sendFile 兜底）。
  remove(bigPath);
  auto stale = repo.get(segsOf("/bui/0.1/big.js"));
  assert(stale.path == repositoryPath(tmp, segsOf("/bui/0.1/big.js")));
}

@("asset get semantics for dyna dir bundles: no index, gzip ignored")
unittest {
  auto tmp = absolutePath(buildPath(tempDir, "micdn-asset-dyna"));
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "dirb", "sub"));
  write(buildPath(tmp, "dirb", "sub", "x.js"), "var x=1;");
  write(buildPath(tmp, "dirb", "sub", "x.js.gz"), "gz");
  bool[string] dyna;
  dyna["dirb"] = true;
  auto repo = new AssetRepo(tmp, dyna.rehash());

  auto rs = repo.get(segsOf("/dirb/sub/x.js"));
  assert(rs.bundle == "dirb");
  assert(rs.info.isFile());
  assert(rs.info.gzSize == 0, "dyna dir ignores gzip even if a sidecar exists on disk");
  assert(repo.get(segsOf("/dirb")).isDir);
  assert(repo.get(segsOf("/dirb/sub")).isDir);
  assert(repo.get(segsOf("/dirb/sub/missing.js")).path is null);
}

@("asset Repository config parse")
unittest {
  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<micdn>
  <static base="~/tmp/static">
    <bundle name="urp">
       <dir location="~/.openurp/static"/>
    </bundle>
    <bundle name="my97">
       <jar gav="org.beangle.bundles:beangle-bundles-my97:4.8"/>
    </bundle>

    <bundle name="bui">
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.1.7"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.1.4"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.2.0"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.2.1"/>
    </bundle>
  </static>
</micdn>`;

  auto dom = parseXml(content);
  auto config = parseAsset("~/tmp", dom);
  assert(config.base == expandTilde("~/tmp/static"));
}
