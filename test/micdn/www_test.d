/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.www_test;

import std.algorithm : endsWith;
import std.file;
import std.path : buildPath, dirName;
import std.zip : ArchiveMember, ZipArchive;
import micdn.config : parse;
import micdn.model;
import micdn.web;
import micdn.www;

/// 测试辅助：uri 字符串 → `ResourceUri`（模拟入口 `getResourceUri` 的语义）。
private ResourceUri segsOf(string uri) {
  return segmentPath(uri);
}

@("WwwRepo maps http path under base")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-test");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "manual"));
  auto html = buildPath(tmp, "manual", "a.html");
  write(html, "<html></html>");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto repo = new WwwRepo(tmp, [new WwwDocConfig("manual", dummy)]);
  auto hit = repo.get(segsOf("/manual/a.html"));
  assert(hit.path == repositoryPath(tmp, segsOf("/manual/a.html")));
  assert(hit.info.isFile(), "hit must carry the resolved file info");
  assert(hit.info.size == cast(ulong) "<html></html>".length);
  auto miss = repo.get(segsOf("/manual/missing.html"));
  assert(miss.path is null);
  assert(!miss.info.isFile(), "miss must not carry file info");
  assert(repo.get(segsOf("/other/x")).path is null);
  assert(repo.get(segsOf("/manual/../etc/passwd")).path is null);
}

@("WwwRepo get ref overload matches value overload")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-refval");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "manual"));
  write(buildPath(tmp, "manual", "a.html"), "ok");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto repo = new WwwRepo(tmp, [new WwwDocConfig("manual", dummy)]);
  auto uri = segsOf("/manual/a.html");
  auto viaRef = repo.get(uri); // lvalue：走 ref 重载
  auto viaVal = repo.get(segsOf("/manual/a.html")); // rvalue：走值重载
  assert(viaRef.path == viaVal.path);
  assert(viaRef.info.isFile());
  assert(viaRef.info.size == viaVal.info.size);
}

@("WwwRepo does not serve files outside any doc")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-nodoc");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "manual"));
  write(buildPath(tmp, "manual", "a.html"), "ok");
  write(buildPath(tmp, "loose.txt"), "loose");

  auto repo = new WwwRepo(tmp);
  assert(repo.get(segsOf("/manual/a.html")).path is null);
  assert(repo.get(segsOf("/loose.txt")).path is null);
}

@("WwwDocTree finds longest doc prefix and falls back on broken chain")
unittest {
  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto docA = new WwwDocConfig("a", dummy);
  auto docAB = new WwwDocConfig("a/b", dummy);
  auto docXYZ = new WwwDocConfig("x/y/z", dummy);
  auto tree = new WwwDocTree([docA, docAB, docXYZ]);

  assert(tree.find(["a"]) is docA);
  assert(tree.find(["a", "b"]) is docAB);
  assert(tree.find(["a", "b", "c"]) is docAB);
  assert(tree.find(["a", "c"]) is docA);
  assert(tree.find(["x", "y", "z"]) is docXYZ);
  assert(tree.find(["x", "y"]) is null);
  assert(tree.find(["x"]) is null);
  assert(tree.find(["other"]) is null);
  assert(tree.find([]) is null);
}

@("WwwDocTree empty tree matches nothing")
unittest {
  auto tree = new WwwDocTree(null);
  assert(tree.find(["a"]) is null);
  assert(tree.find([]) is null);
}

@("WwwDocTree falls back to doc above doc-less intermediate node")
unittest {
  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto docA = new WwwDocConfig("a", dummy);
  auto docABC = new WwwDocConfig("a/b/c", dummy);
  auto tree = new WwwDocTree([docA, docABC]);

  assert(tree.find(["a", "b", "x"]) is docA);
  assert(tree.find(["a", "b"]) is docA);
  assert(tree.find(["a"]) is docA);
  assert(tree.find(["a", "b", "c"]) is docABC);
  assert(tree.find(["a", "b", "c", "d"]) is docABC);
  assert(tree.find(["x"]) is null);
}

@("WwwDocTree rejects duplicate doc endpoint")
unittest {
  import std.exception;

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  assertThrown!Exception(new WwwDocTree([
    new WwwDocConfig("a", dummy),
    new WwwDocConfig("a", dummy),
  ]));
}

@("WwwRepo traversal protection lives at the entry")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-safe");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  // 编码穿越在入口 `getResourceUri`/`segmentPath` 消解或拒绝
  assert(!segmentPath(decodeRepositoryUri("/%2e%2e%2fsecret.txt")).ok);
  assert(decodeRepositoryUri("/%5cWindows%5cwin.ini") is null);
}

@("WwwRepo normalizes dot segments before matching")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-dotseg");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "manual"));
  write(buildPath(tmp, "manual", "a.html"), "ok");
  write(buildPath(tmp, "secret.txt"), "secret");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto repo = new WwwRepo(tmp, [new WwwDocConfig("manual", dummy)]);

  // `.` 与空段等价于原路径，照常命中
  assert(repo.get(segsOf("/manual/./a.html")).path !is null);
  assert(repo.get(segsOf("/manual//a.html")).path !is null);
  // `..` 抵消回 doc 根下：/manual/../manual/a.html → /manual/a.html
  assert(repo.get(segsOf("/manual/../manual/a.html")).path !is null);
  // 抵消到 doc 树根（不属于任何 doc）→ 404
  assert(repo.get(segsOf("/manual/..")).path is null);
  // 弹栈越界（试图逃出根）在入口拒绝
  assert(!segsOf("/../../etc/passwd").ok);
  assert(!segsOf("/manual/../../etc/passwd").ok);
}

@("WwwRepo try-file skips fallback for missing static assets")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-tryfile-static");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  auto docRoot = buildPath(tmp, "app");
  mkdirRecurse(buildPath(docRoot, "assets"));
  write(buildPath(docRoot, "index.html"), "spa");
  write(buildPath(docRoot, "assets", "ok.js"), "js");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto doc = new WwwDocConfig("app", dummy, "index.html");
  auto repo = new WwwRepo(tmp, [doc]);

  assert(repo.get(segsOf("/app/route/foo")).path !is null);
  assert(repo.get(segsOf("/app/route/foo")).path.endsWith("index.html"));
  assert(repo.get(segsOf("/app/assets/ok.js")).path !is null);
  assert(repo.get(segsOf("/app/assets/missing.js")).path is null);
  assert(repo.get(segsOf("/app/missing.css")).path is null);
  assert(repo.get(segsOf("/app/missing.woff2")).path is null);
}

@("WwwRepo try-file falls back for spa deep link")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-tryfile");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  auto docRoot = buildPath(tmp, "m", "edu", "learning");
  mkdirRecurse(docRoot);
  write(buildPath(docRoot, "index.html"), "spa");
  write(buildPath(docRoot, "app.js"), "js");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto doc = new WwwDocConfig("m/edu/learning", dummy, "index.html");
  auto repo = new WwwRepo(tmp, [doc]);

  assert(repo.get(segsOf("/m/edu/learning/app.js")).path !is null);
  assert(repo.get(segsOf("/m/edu/learning/app.js")).path.endsWith("app.js"));
  assert(repo.get(segsOf("/m/edu/learning/route/foo")).path !is null);
  assert(repo.get(segsOf("/m/edu/learning/route/foo")).path.endsWith("index.html"));
  assert(repo.get(segsOf("/other/route")).path is null);
}

@("WwwRepo try-file falls back for m/edu/teaching deep link")
unittest {
  auto home = buildPath(tempDir, "micdn-www-teaching");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto zipPath = buildPath(home, "teaching.zip");
  mkdirRecurse(dirName(zipPath));
  auto m = new ArchiveMember();
  m.name = "index.html";
  m.expandedData(cast(ubyte[]) "spa");
  auto z = new ZipArchive();
  z.addMember(m);
  write(zipPath, z.build());

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="m/edu/teaching" zip="` ~ zipPath ~ `" try-file="index.html" />
  </www>
</micdn>`;
  auto config = parse(home, xml);
  auto repo = WwwRepo.build(config);

  assert(repo.get(segsOf("/m/edu/teaching")).path !is null);
  assert(repo.get(segsOf("/m/edu/teaching/a/bc")).path !is null);
  assert(repo.get(segsOf("/m/edu/teaching/a/bc")).path.endsWith("index.html"));
}

@("WwwRepo try-file missing yields null path with doc kept")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-tryfile-missing");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "app"));

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto doc = new WwwDocConfig("app", dummy, "index.html");
  auto repo = new WwwRepo(tmp, [doc]);

  auto miss = repo.get(segsOf("/app/route/foo"));
  assert(miss.path is null, "missing try-file must not fall back to a stale path");
  assert(miss.doc is doc);
}

@("deployDoc warns when try-file missing after mount")
unittest {
  auto home = buildPath(tempDir, "micdn-www-tryfile-mount-warn");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto zipPath = buildPath(home, "spa.zip");
  mkdirRecurse(dirName(zipPath));
  auto m = new ArchiveMember();
  m.name = "app.js";
  m.expandedData(cast(ubyte[]) "js");
  auto z = new ZipArchive();
  z.addMember(m);
  write(zipPath, z.build());

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="spa" zip="` ~ zipPath ~ `" try-file="index.html" />
  </www>
</micdn>`;
  auto config = parse(home, xml);
  assert(cast(ZipProvider) config.www.docs[0].provider !is null);
  assert(WwwRepo.deployDoc(config, config.www.docs[0]));
  // 直接构造（未走 build 归一化）：try-file 缺失时请求期同样不回退
  auto repo = new WwwRepo(config.www.base, config.www.docs);
  auto miss = repo.get(segsOf("/spa/deep/link"));
  assert(miss.path is null, "missing try-file must not be served as fallback");
  assert(miss.doc !is null);
}

@("WwwRepo.build drops try-file missing after mount")
unittest {
  auto home = buildPath(tempDir, "micdn-www-tryfile-build-drop");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto zipPath = buildPath(home, "spa.zip");
  mkdirRecurse(dirName(zipPath));
  auto m = new ArchiveMember();
  m.name = "app.js";
  m.expandedData(cast(ubyte[]) "js");
  auto z = new ZipArchive();
  z.addMember(m);
  write(zipPath, z.build());

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="spa" zip="` ~ zipPath ~ `" try-file="index.html" />
  </www>
</micdn>`;
  auto config = parse(home, xml);
  auto repo = WwwRepo.build(config);
  assert(repo.docs.length == 1);
  assert(repo.docs[0].tryFile == "", "build must drop try-file that failed to deploy");
  auto miss = repo.get(segsOf("/spa/deep/link"));
  assert(miss.path is null);
  assert(miss.doc is repo.docs[0]);
}

@("WwwRepo try-file uses longest doc prefix")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-tryfile-prefix");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "a"));
  mkdirRecurse(buildPath(tmp, "a", "b"));
  write(buildPath(tmp, "a", "index.html"), "a");
  write(buildPath(tmp, "a", "b", "index.html"), "ab");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto docs = [
    new WwwDocConfig("a", dummy, "index.html"),
    new WwwDocConfig("a/b", dummy, "index.html"),
  ];
  auto repo = new WwwRepo(tmp, docs);

  assert(repo.get(segsOf("/a/b/x")).path.endsWith(buildPath("a", "b", "index.html")));
  assert(repo.get(segsOf("/a/x")).path.endsWith(buildPath("a", "index.html")));
}

@("WwwRepo get carries matched doc with auto-gzip flag")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-autogzip");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "app"));
  write(buildPath(tmp, "app", "index.html"), "spa");
  mkdirRecurse(buildPath(tmp, "plain"));
  write(buildPath(tmp, "plain", "index.html"), "plain");

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto repo = new WwwRepo(tmp, [
    new WwwDocConfig("app", dummy, "index.html", false, false),
    new WwwDocConfig("plain", dummy),
  ]);
  auto hit = repo.get(segsOf("/app/route"));
  assert(hit.path.endsWith("index.html"));
  assert(hit.doc.autoGzip == false);
  auto plain = repo.get(segsOf("/plain/"));
  assert(plain.doc.autoGzip == true);
  assert(plain.info.isFile(), "directory index must carry index.html info");
  assert(repo.get(segsOf("/missing")).path is null);
}

@("WwwRepo get keeps matched doc on missing file")
unittest {
  auto tmp = buildPath(tempDir, "micdn-www-missdoc");
  scope (exit)
    if (exists(tmp))
      rmdirRecurse(tmp);
  mkdirRecurse(buildPath(tmp, "app"));

  auto dummy = new ZipProvider("/tmp/placeholder.zip", "");
  auto doc = new WwwDocConfig("app", dummy);
  auto repo = new WwwRepo(tmp, [doc]);

  auto miss = repo.get(segsOf("/app/route/x"));
  assert(miss.path is null);
  assert(miss.doc is doc);
  assert(repo.get(segsOf("/other/x")).doc is null);
}

@("WwwRepo build index serves file, dir fold, spa and 404 without stat")
unittest {
  auto home = buildPath(tempDir, "micdn-www-index-serve");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto zipPath = buildPath(home, "site.zip");
  mkdirRecurse(dirName(zipPath));
  auto z = new ZipArchive();
  auto add = (string name, string data) {
    auto m = new ArchiveMember();
    m.name = name;
    m.expandedData(cast(ubyte[]) data);
    z.addMember(m);
  };
  add("index.html", "spa");
  add("assets/app.js", "js");
  add("docs/index.html", "doc");
  write(zipPath, z.build());

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="manual" zip="` ~ zipPath ~ `" try-file="index.html" />
  </www>
</micdn>`;
  auto repo = WwwRepo.build(parse(home, xml));

  auto fileHit = repo.get(segsOf("/manual/assets/app.js"));
  assert(fileHit.path !is null && fileHit.path.endsWith("app.js"));
  assert(fileHit.info.isFile() && fileHit.info.size == 2);
  auto dirFold = repo.get(segsOf("/manual/docs"));
  assert(dirFold.path !is null && dirFold.path.endsWith(buildPath("docs", "index.html")));
  auto spa = repo.get(segsOf("/manual/route/foo"));
  assert(spa.path !is null && spa.path.endsWith("index.html"));
  assert(repo.get(segsOf("/manual/assets/missing.js")).path is null, "static asset must not fall back to try-file");
  auto bin = repo.get(segsOf("/manual/unknown.bin"));
  assert(bin.path !is null && bin.path.endsWith("index.html"), "non-static unknown path falls back to try-file");
}

@("WwwRepo index is authoritative until rebuildIndex refreshes it")
unittest {
  auto home = buildPath(tempDir, "micdn-www-index-rebuild");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto zipPath = buildPath(home, "site.zip");
  mkdirRecurse(dirName(zipPath));
  auto m = new ArchiveMember();
  m.name = "a.js";
  m.expandedData(cast(ubyte[]) "a");
  auto z = new ZipArchive();
  z.addMember(m);
  write(zipPath, z.build());

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="manual" zip="` ~ zipPath ~ `" />
  </www>
</micdn>`;
  auto repo = WwwRepo.build(parse(home, xml));
  assert(repo.get(segsOf("/manual/a.js")).path !is null);
  assert(repo.get(segsOf("/manual/b.js")).path is null, "files added outside deploy are not visible to the index");

  write(buildPath(home, "www", "manual", "b.js"), "b");
  assert(repo.get(segsOf("/manual/b.js")).path is null, "index is authoritative until rebuild");

  repo.rebuildIndex("manual");
  assert(repo.get(segsOf("/manual/b.js")).path !is null, "rebuildIndex must pick up redeployed files");
}

@("WwwRepo index attaches gzip sidecar to source node")
unittest {
  auto home = buildPath(tempDir, "micdn-www-index-gz");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto zipPath = buildPath(home, "site.zip");
  mkdirRecurse(dirName(zipPath));
  auto m = new ArchiveMember();
  m.name = "a.js";
  m.expandedData(cast(ubyte[]) "a");
  auto z = new ZipArchive();
  z.addMember(m);
  write(zipPath, z.build());

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="manual" zip="` ~ zipPath ~ `" />
  </www>
</micdn>`;
  auto repo = WwwRepo.build(parse(home, xml));

  // 部署期预压缩对小文件（<1KB）不生成 sidecar；手动写入并重建索引验证挂载逻辑。
  write(buildPath(home, "www", "manual", "a.js.gz"), "gz");
  repo.rebuildIndex("manual");

  auto hit = repo.get(segsOf("/manual/a.js"));
  assert(hit.path !is null && hit.info.gzSize != 0, "sidecar size must be attached to the source node");
  assert(hit.info.gzSize == getSize(buildPath(home, "www", "manual", "a.js.gz")));
  assert(repo.get(segsOf("/manual/a.js.gz")).path is null, "gz sidecar is not addressable as content");
}

@("WwwRepo deploy precompresses autoGzip doc and index attaches sidecar")
unittest {
  auto home = buildPath(tempDir, "micdn-www-precompress");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto zipPath = buildPath(home, "site.zip");
  mkdirRecurse(dirName(zipPath));
  string bigContent;
  foreach (i; 0 .. 200)
    bigContent ~= "var k = 1; console.log('x');\n";
  auto m = new ArchiveMember();
  m.name = "big.js";
  m.expandedData(cast(ubyte[]) bigContent);
  auto z = new ZipArchive();
  z.addMember(m);
  write(zipPath, z.build());

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="manual" zip="` ~ zipPath ~ `" />
  </www>
</micdn>`;
  auto repo = WwwRepo.build(parse(home, xml));

  auto gzPath = buildPath(home, "www", "manual", "big.js.gz");
  assert(exists(gzPath), "autoGzip doc must be precompressed at deploy time");
  auto hit = repo.get(segsOf("/manual/big.js"));
  assert(hit.info.gzSize != 0, "index must attach the deploy-time sidecar");
  assert(hit.info.gzSize == getSize(gzPath));
}

@("WwwRepo auto-gzip=false skips deploy precompression")
unittest {
  auto home = buildPath(tempDir, "micdn-www-nogzip");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto zipPath = buildPath(home, "site.zip");
  mkdirRecurse(dirName(zipPath));
  string bigContent;
  foreach (i; 0 .. 200)
    bigContent ~= "var k = 1; console.log('x');\n";
  auto m = new ArchiveMember();
  m.name = "big.js";
  m.expandedData(cast(ubyte[]) bigContent);
  auto z = new ZipArchive();
  z.addMember(m);
  write(zipPath, z.build());

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="manual" zip="` ~ zipPath ~ `" auto-gzip="false" />
  </www>
</micdn>`;
  auto repo = WwwRepo.build(parse(home, xml));

  assert(!exists(buildPath(home, "www", "manual", "big.js.gz")), "auto-gzip=false must not precompress");
  assert(repo.get(segsOf("/manual/big.js")).info.gzSize == 0);
}

@("WwwRepo redeploy skips precompression when deploy skipped via manifest")
unittest {
  auto home = buildPath(tempDir, "micdn-www-redeploy-gzip");
  scope (exit)
    if (exists(home))
      rmdirRecurse(home);
  auto zipPath = buildPath(home, "site.zip");
  mkdirRecurse(dirName(zipPath));
  string bigContent;
  foreach (i; 0 .. 200)
    bigContent ~= "var k = 1; console.log('x');\n";
  auto m = new ArchiveMember();
  m.name = "big.js";
  m.expandedData(cast(ubyte[]) bigContent);
  auto z = new ZipArchive();
  z.addMember(m);
  write(zipPath, z.build());

  auto xml = `<?xml version="1.0"?><micdn>
  <maven/><npm/>
  <www base="` ~ home ~ `/www">
    <doc name="manual" zip="` ~ zipPath ~ `" />
  </www>
</micdn>`;
  auto config = parse(home, xml);
  WwwRepo.build(config);
  auto gzPath = buildPath(home, "www", "manual", "big.js.gz");
  assert(exists(gzPath), "first deploy must precompress autoGzip doc");

  // 已部署未变更：再次启动走 manifest 快路径跳过解压，不补齐缺失的 sidecar。
  remove(gzPath);
  WwwRepo.build(config);
  assert(!exists(gzPath), "manifest-skipped redeploy must not re-precompress");
}
