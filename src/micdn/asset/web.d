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

import std.string;

import vibe.core.core;
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
import micdn.xml;

class AssetService {
  private enum string endpoint = mountStatic;
  private const AssetRepo repo;

  this(MicdnConfig config) {
    this.repo = AssetRepo.build(config);
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    const uri = getPath(endpoint, req);
    const rs = repo.get(uri);
    if (rs.path is null)
      throw new HTTPStatusException(HTTPStatus.notFound);

    // 目录：HEAD 拒绝，`/` 结尾列表、否则重定向补 `/`（`isDir` 由 repo.get 判定：索引或单次 stat）。
    if (rs.isDir) {
      if (req.method == HTTPMethod.HEAD)
        throw new HTTPStatusException(HTTPStatus.methodNotAllowed);
      if (uri.endsWith("/")) {
        auto listData = genListContents(rs.path, endpoint, uri);
        render!("index.dt", listData)(res);
      } else {
        auto pub = endpoint ~ uri;
        res.redirect(req.requestURI.replace(pub, pub ~ "/"));
      }
      return;
    }

    void setCORS(scope HTTPServerRequest req, scope HTTPServerResponse res) @safe {
      res.headers["Access-Control-Allow-Origin"] = "*";
    }

    // 非 `<dir>` bundle：info 含 gzSize（强制 gzip）；`<dir>` dyna：gzSize 为 0（忽略 gzip）。
    sendFile(req, res, rs.path, rs.info, assetBundleCachePolicy(repo.isDynaBundle(rs.bundle)), &setCORS);
  }
}
