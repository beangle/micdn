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

module test.micdn.web.server_test;

import std.file;
import std.path;
import micdn.web;
import micdn.config;

@("web server parse config")
unittest {
  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<micdn listen="192.168.31.244:8081">
</micdn>`;
  auto server = parse("~/ems/micdn", content);
  assert(server.listen == "192.168.31.244:8081");

  string test = "~/ems/micdn/asset.xml";
  assert(dirName(test) == "~/ems/micdn");
}

@("extract remote attr from xml text")
unittest {
  // 双引号
  assert(extractRemoteUrl(`<micdn remote="http://example.com/micdn.xml">`) == "http://example.com/micdn.xml");
  assert(extractRemoteUrl(`<micdn listen="0:8888" remote="https://cdn.example.com/config.xml">`)
      == "https://cdn.example.com/config.xml");
  // 单引号
  assert(extractRemoteUrl(`<micdn remote='http://a.com/b.xml'>`) == "http://a.com/b.xml");
  // 无 remote
  assert(extractRemoteUrl(`<micdn listen="127.0.0.1:8888">`) is null);
  assert(extractRemoteUrl(`<micdn>`) is null);
  // remote 有空格
  assert(extractRemoteUrl(`<micdn remote = "http://x.com/c.xml">`) == "http://x.com/c.xml");
}

@("repository path builds absolute path from entry segments")
unittest {
  auto base = buildNormalizedPath(tempDir(), "micdn-repo-safe");
  auto goodUri = segmentPath(decodeRepositoryUri("/org/example/app/1.0/app-1.0.jar"));
  auto goodPath = repositoryPath(base, goodUri);
  assert(goodPath == buildPath(base, "org", "example", "app", "1.0", "app-1.0.jar"));
  assert(baseName(goodPath) == "app-1.0.jar");

  // 编码穿越在入口切段阶段拒绝（`resolveRepositoryPath` 已移除，防穿越收敛到 `getResourceUri`/`segmentPath`）
  assert(!segmentPath(decodeRepositoryUri("/%2e%2e%2fsecret.txt")).ok);
  assert(decodeRepositoryUri("/%5cWindows%5cwin.ini") is null);
}

@("segmentPath splits, resolves dot segments and keeps trailing slash")
unittest {
  assert(segmentPath("/org/example/app").segs == ["org", "example", "app"]);
  assert(!segmentPath("/org/example/app").slashEnded);
  assert(segmentPath("/manual/a.html").segs == ["manual", "a.html"]);
  assert(segmentPath("/manual/").segs == ["manual"]);
  assert(segmentPath("/manual/").slashEnded);
  assert(segmentPath("/").segs.length == 0);
  assert(segmentPath("/").slashEnded);
  // `.` 与中间空段合并
  assert(segmentPath("/manual/./a.html").segs == ["manual", "a.html"]);
  assert(segmentPath("/manual//a.html").segs == ["manual", "a.html"]);
  // `..` 抵消前一段
  assert(segmentPath("/manual/../manual/a.html").segs == ["manual", "a.html"]);
  assert(segmentPath("/manual/..").segs.length == 0);
  // 弹栈越界（试图逃出根）拒绝
  assert(!segmentPath("/..").ok);
  assert(!segmentPath("/manual/../..").ok);
}

@("repositoryUri rebuilds uri honoring slashEnded")
unittest {
  assert(repositoryUri(ResourceUri(["org", "beangle"], true)) == "/org/beangle/");
  assert(repositoryUri(ResourceUri(["org", "beangle"], false)) == "/org/beangle");
  assert(repositoryUri(ResourceUri([], true)) == "/");
  assert(repositoryUri(ResourceUri([], false)) == "/");
}

@("repositoryPath builds absolute path from normalized segments")
unittest {
  auto base = buildNormalizedPath(tempDir(), "micdn-repo-path");
  assert(repositoryPath(base, ResourceUri(["org", "beangle"], false)) == buildPath(base, "org", "beangle"));
  // slashEnded 不影响物理路径
  assert(repositoryPath(base, ResourceUri(["org", "beangle"], true)) == buildPath(base, "org", "beangle"));
  assert(repositoryPath(base, ResourceUri([], false)) == base);
  assert(repositoryPath(base, ResourceUri([], true)) == base);
}
