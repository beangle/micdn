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
import std.path;
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
import micdn.routes;
import micdn.web;
import micdn.web.cache;
import micdn.web.file;
import micdn.fs.browser;
import micdn.web.server;
import micdn.xml;

/// 末段路径含 `.` 则按文件处理（可拉取）；不含则按目录。不解析具体后缀名。
private bool looksLikeMavenArtifactFile(string uri) {
  auto name = baseName(uri);
  return name.length > 0 && name.indexOf('.') >= 0;
}

class MavenService {
  private enum string endpoint = mountMaven;
  private const GavRepo repo;

  this(MicdnConfig config) {
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
        if (req.method == HTTPMethod.HEAD) {
          throw new HTTPStatusException(HTTPStatus.methodNotAllowed);
        }
        if (uri.endsWith("/")) {
          auto listData = genListContents(repo.base ~ uri, endpoint, uri);
          render!("index.dt", listData)(res);
        } else {
          auto pub = endpoint ~ uri;
          res.redirect(req.requestURI.replace(pub, pub ~ "/"));
        }
      } else {
        sendFile(req, res, file, mavenArtifactCachePolicy(uri));
      }
    } else {
      if (uri.endsWith(".diff")) {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
      // 目录型 URL：本地不存在则直接 404，不重定向（重定向后仍无列表内容）
      if (uri.endsWith("/") || !looksLikeMavenArtifactFile(uri)) {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
      if (repo.fetch(uri)) {
        sendFile(req, res, file, mavenArtifactCachePolicy(uri));
      } else {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
    }
  }
}
