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

module micdn.admin.web;
/// 管理接口服务，提供 /admin/config.xml 等运维接口。

import vibe.core.core;
import vibe.http.router;
import vibe.http.server;

import micdn.model;
import micdn.web;
import micdn.config;

/// 管理服务，挂载于 /admin 下，提供配置查看等接口。
class AdminService {
  private const string endpoint = "/admin";
  private const MicdnConfig config;

  this(MicdnConfig config) {
    this.config = config;
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto uri = getPath(endpoint, req);
    auto path = (uri.length > 0 && uri[0] != '/') ? "/" ~ uri : uri;
    if (path == "/config.xml") {
      res.statusCode = HTTPStatus.ok;
      res.headers["Content-Type"] = "application/xml; charset=utf-8";
      res.writeBody(config.toXml());
    } else {
      throw new HTTPStatusException(HTTPStatus.notFound);
    }
  }
}
