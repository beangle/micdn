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
/// 管理接口服务，提供 /admin/config.xml、/admin/metrics 等运维接口。

import vibe.http.router;
import vibe.http.server;
import vibe.web.web;

import micdn.admin.access : requireLocalhostPeer;
import micdn.admin.metrics : metricsJson, snapshotMetrics;
import micdn.config;
import micdn.model;
import micdn.web;

struct MetricsPageData {
  string appVersion;
}

struct ReloadResult {
  bool ok;
  string error;
  ushort listenPort;
  MicdnConfig config;
}

/// 管理服务，挂载于 /admin 下，提供配置查看、reload 等接口。
class AdminService {
  private const string endpoint = "/admin";
  private const MicdnConfig config;
  private const string appVersion;
  private ReloadResult delegate() onReload;

  this(MicdnConfig config, string appVersion, ReloadResult delegate() onReload = null) {
    this.config = config;
    this.appVersion = appVersion;
    this.onReload = onReload;
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    const path = getPath(endpoint, req);
    if (path == "/config.xml") {
      res.statusCode = HTTPStatus.ok;
      res.headers["Content-Type"] = "application/xml; charset=utf-8";
      res.writeBody(config.toXml());
    } else if (path == "/reload" && onReload !is null) {
      requireLocalhostPeer(req);
      auto result = onReload();
      if (result.ok) {
        res.statusCode = HTTPStatus.ok;
        res.headers["Content-Type"] = "text/plain; charset=utf-8";
        res.writeBody("reload ok");
      } else {
        res.statusCode = HTTPStatus.internalServerError;
        res.headers["Content-Type"] = "text/plain; charset=utf-8";
        res.writeBody("reload failed: " ~ result.error);
      }
    } else if (path == "/metrics.json") {
      requireLocalhostPeer(req);
      res.statusCode = HTTPStatus.ok;
      res.headers["Content-Type"] = "application/json; charset=utf-8";
      res.writeBody(metricsJson(snapshotMetrics()));
    } else if (path == "/metrics") {
      requireLocalhostPeer(req);
      auto pageData = MetricsPageData(appVersion);
      render!("metrics.dt", pageData)(res);
    } else {
      throw new HTTPStatusException(HTTPStatus.notFound);
    }
  }
}
