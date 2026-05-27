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

module micdn.www.web;
/// WWW 文档服务入口，按 endpoint 提供静态文件，不提供目录列表；缓存见 `wwwDocCachePolicy`。

import std.exception;
import std.file;
import std.string;

import vibe.http.router;
import vibe.http.server;

import micdn.model;
import micdn.web;
import micdn.web.cache;
import micdn.web.file;
import micdn.www;

class WwwDocService {
  private const string endpoint;
  private const WwwDocRepo repo;

  this(const WwwDocConfig doc, WwwDocRepo repo) {
    this.endpoint = doc.location;
    this.repo = repo;
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto uri = getPath(endpoint, req);
    string path = uri;
    if (path.length > 0 && !path.startsWith("/"))
      path = "/" ~ path;

    auto rs = repo.get(path);
    if (rs is null) {
      throw new HTTPStatusException(HTTPStatus.notFound);
    }

    void setCORS(scope HTTPServerRequest req, scope HTTPServerResponse res) @safe {
      res.headers["Access-Control-Allow-Origin"] = "*";
    }

    sendFile(req, res, rs, wwwDocCachePolicy(rs), &setCORS);
  }
}
