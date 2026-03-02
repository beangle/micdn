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
import micdn.web.server;
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
  assert(extractRemoteUrl(`<micdn listen="0:8888" remote="https://cdn.example.com/config.xml">`) == "https://cdn.example.com/config.xml");
  // 单引号
  assert(extractRemoteUrl(`<micdn remote='http://a.com/b.xml'>`) == "http://a.com/b.xml");
  // 无 remote
  assert(extractRemoteUrl(`<micdn listen="127.0.0.1:8888">`) is null);
  assert(extractRemoteUrl(`<micdn>`) is null);
  // remote 有空格
  assert(extractRemoteUrl(`<micdn remote = "http://x.com/c.xml">`) == "http://x.com/c.xml");
}
