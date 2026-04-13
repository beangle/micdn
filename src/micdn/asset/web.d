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

module micdn.asset.web;
/// 静态资源服务入口，挂载资源上下文并提供 HTTP 访问。

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

import micdn.asset;
import micdn.fs.browser;
import micdn.model;
import micdn.routes;
import micdn.web;
import micdn.web.cache;
import micdn.web.file;
import micdn.web.server;
import micdn.xml;

class AssetService {
  private enum string endpoint = mountStatic;
  private const AssetRepo repo;

  this(MicdnConfig config) {
    this.repo = AssetRepo.build(config);
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto uri = getPath(endpoint, req);
    auto rs = repo.get(uri);
    if (null == rs) {
      throw new HTTPStatusException(HTTPStatus.notFound);
    } else {
      // dir
      if (isDir(rs[0])) {
        if (req.method == HTTPMethod.HEAD) {
          throw new HTTPStatusException(HTTPStatus.methodNotAllowed);
        }
        if (uri.endsWith("/")) {
          auto listData = genListContents(repo.base ~ uri, endpoint, uri);
          render!("index.dt", listData)(res);
        } else {
          uri = endpoint ~ uri;
          res.redirect(req.requestURI.replace(uri, uri ~ "/"));
        }
      } else {
        void setCORS(scope HTTPServerRequest req, scope HTTPServerResponse res) @safe {
          res.headers["Access-Control-Allow-Origin"] = "*";
        }

        auto policy = assetBundleCachePolicy(repo.isDynaBundle(uri));
        if (rs.length == 1) {
          sendFile(req, res, rs[0], policy, &setCORS);
        } else {
          sendFiles(req, res, rs, policy, &setCORS);
        }
      }
    }
  }
}
