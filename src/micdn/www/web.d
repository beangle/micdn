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
/// WWW 兜底静态服务：在内置路由之后匹配 `<doc location>`，不提供目录列表。

import std.exception;

import vibe.core.file : FileInfo;
import vibe.http.server;

import micdn.web;
import micdn.web.cache;
import micdn.web.file;
import micdn.www;

/// 注册于 `/*` 的兜底 handler。
class WwwService {
  private static __gshared WwwService active;
  private WwwRepo repo;

  this(WwwRepo repo) {
    this.repo = repo;
    active = this;
  }

  /// autodeploy 重新部署某 doc 后重建其发布期索引（单服务实例，reload 时由新实例接管）。
  static void invalidateDoc(string docName) {
    if (active !is null)
      active.repo.rebuildIndex(docName);
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto uri = getResourceUri("", req);
    auto rs = repo.get(uri);
    if (rs.path is null)
      throw new HTTPStatusException(HTTPStatus.notFound);

    void setCORS(scope HTTPServerRequest req, scope HTTPServerResponse res) @safe {
      res.headers["Access-Control-Allow-Origin"] = "*";
    }

    // gzip 预压缩按 doc 的 auto-gzip 开关（默认参与）：sidecar 信息随 rs.info.gzSize 传入，
    // sendFile 内部决定是否发送 path.gz（modified/flags 复用源文件，缓存元数据稳定）。
    sendFile(req, res, rs.path, rs.info, wwwDocCachePolicy(rs.path), &setCORS);
  }
}
