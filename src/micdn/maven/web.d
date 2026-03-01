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

module micdn.maven.web;
/// Maven 代理 HTTP 服务入口，转发并缓存上游 Maven 仓库。

import std.exception;
import std.file;
import std.stdio;
import std.string;

import vibe.core.core;
import vibe.core.file;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.web.web;

import micdn.maven;
import micdn.model;
import micdn.web;
import micdn.web.file;
import micdn.fs.browser;
import micdn.web.server;
import micdn.xml;

class MavenService {
  private const string endpoint;
  private const GavRepo repo;

  this(MicdnConfig config) {
    this.endpoint = config.maven.endpoint;
    this.repo = GavRepo.build(config);
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto uri = getPath(endpoint, req);
    if (uri.indexOf("..") > -1)
      throw new HTTPStatusException(HTTPStatus.notFound);

    import vibe.textfilter.urlencode;

    auto file = urlDecode(repo.base ~ uri);
    if (exists(file)) {
      if (isDir(file)) {
        if (uri.endsWith("/")) {
          auto listData = genListContents(repo.base ~ uri, endpoint, uri);
          render!("index.dt", listData)(res);
        } else {
          uri = endpoint ~ uri;
          res.redirect(req.requestURI.replace(uri, uri ~ "/"));
        }
      } else {
        sendFile(req, res, file);
      }
    } else {
      if (uri.endsWith(".diff")) {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
      if (repo.fetch(uri)) {
        sendFile(req, res, file);
      } else {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
    }
  }
}
