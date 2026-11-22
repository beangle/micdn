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
/// 管理接口服务：/admin/config.xml 查看、/admin/reload 本地重载。

import std.format : format;

import vibe.core.log : logInfo;
import vibe.http.router;
import vibe.http.server;

import micdn.admin.access : requireLocalhostPeer;
import micdn.admin.metrics : metricsJson, snapshotMetrics;
import micdn.config;
import micdn.maven.gc : pruneSnapshotBuilds;
import micdn.model;
import micdn.npm.packument : pruneDevVersions;
import micdn.runtime : runGcMinimize;
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
    const path = repositoryUri(getResourceUri(endpoint, req));
    if (path == "/config.xml") {
      res.statusCode = HTTPStatus.ok;
      res.headers["Content-Type"] = "application/xml; charset=utf-8";
      res.writeBody(config.toXml());
    } else if (path == "/reload" && onReload !is null) {
      requireLocalhostPeer(req);
      auto result = onReload();
      if (result.ok) {
        logInfo("Config reload (HTTP): ok");
        res.statusCode = HTTPStatus.ok;
        res.headers["Content-Type"] = "text/plain; charset=utf-8";
        res.writeBody("reload ok");
      } else {
        res.statusCode = HTTPStatus.internalServerError;
        res.headers["Content-Type"] = "text/plain; charset=utf-8";
        res.writeBody("reload failed: " ~ result.error);
      }
    } else if (path == "/prune") {
      // 本机手动触发（bashub/basagent 也只打这个地址）；同步执行，仓库很大时会占用事件循环，
      // 日常清理优先交给 <prune> 的夜间定时任务。
      requireLocalhostPeer(req);
      // 没有 <prune> 时按默认各保留 1 份，与 CLI 的默认值一致。
      auto keepDev = config.prune !is null ? config.prune.npmDevKeep : 1;
      auto keepMaven = config.prune !is null ? config.prune.mavenSnapshotKeep : 1;
      auto npmResult = pruneDevVersions(config.npm.base, keepDev);
      auto mavenResult = pruneSnapshotBuilds(config.maven.base, keepMaven);
      logInfo("Prune (HTTP): npm %s versions/%s dirs, maven %s builds/%s files",
          npmResult.versionsRemoved, npmResult.dirsRemoved,
          mavenResult.buildsRemoved, mavenResult.filesRemoved);
      res.statusCode = HTTPStatus.ok;
      res.headers["Content-Type"] = "application/json; charset=utf-8";
      res.headers["Cache-Control"] = "no-store";
      res.writeBody(format(
          `{"npm":{"packages":%s,"versions":%s,"dirs":%s},"maven":{"versions":%s,"builds":%s,"files":%s}}`,
          npmResult.packages, npmResult.versionsRemoved, npmResult.dirsRemoved,
          mavenResult.versions, mavenResult.buildsRemoved, mavenResult.filesRemoved));
    } else if (path == "/metrics.json") {
      requireLocalhostPeer(req);
      res.statusCode = HTTPStatus.ok;
      res.headers["Content-Type"] = "application/json; charset=utf-8";
      res.writeBody(metricsJson(snapshotMetrics()));
    } else if (path == "/reclaim") {
      requireLocalhostPeer(req);
      auto r = runGcMinimize();
      res.statusCode = HTTPStatus.ok;
      res.headers["Content-Type"] = "application/json; charset=utf-8";
      res.writeBody(format(
          `{"before":{"rssKb":%s,"hwmKb":%s,"gcUsed":%s,"gcFree":%s},"after":{"rssKb":%s,"hwmKb":%s,"gcUsed":%s,"gcFree":%s},"mallocTrim":%s}`,
          r.before.process.rssKb, r.before.process.hwmKb, r.before.gc.usedBytes, r.before.gc.freeBytes,
          r.after.process.rssKb, r.after.process.hwmKb, r.after.gc.usedBytes, r.after.gc.freeBytes,
          r.mallocTrim));
    } else if (path == "/metrics") {
      requireLocalhostPeer(req);
      auto pageData = MetricsPageData(appVersion);
      render!("metrics.dt", pageData)(res);
    } else {
      throw new HTTPStatusException(HTTPStatus.notFound);
    }
  }
}
