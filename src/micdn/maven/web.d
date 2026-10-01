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
/// Maven 代理 HTTP 服务入口，转发并缓存上游 Maven 仓库（正式版与 SNAPSHOT 同一个入口）。

import std.exception;
import std.path;
import std.stdio;
import std.string;

import vibe.core.core;
import vibe.core.file;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;

import micdn.maven;
import micdn.maven.snapshot;
import micdn.model;
import micdn.routes;
import micdn.web;
import micdn.web.cache;
import micdn.web.file;
import micdn.fs.index;
import micdn.fs.browser;
import micdn.xml;

/// 末段路径含 `.` 则按文件处理（可拉取）；不含则按目录。不解析具体后缀名。
private bool looksLikeMavenArtifactFile(string uri) {
  auto name = baseName(uri);
  return name.length > 0 && name.indexOf('.') >= 0;
}

class MavenService {
  private enum string endpoint = mountMaven;
  private const GavRepo repo;
  /** 本地快照布局与「不带时间戳的别名 → 最新时间戳文件」解析（与 `repo` 共用同一 base）。 */
  private const SnapshotRepo snapshots;

  this(MicdnConfig config) {
    this.repo = GavRepo.build(config);
    this.snapshots = SnapshotRepo.build(config);
  }

  /** 单个 `/maven` 入口同时服务正式版与 SNAPSHOT，按版本目录区分：

      1. 不带时间戳的快照别名（`{artifact}-{version}-SNAPSHOT.{ext}[.sha1]`）重定向到本地同目录
         最新的时间戳文件，`HEAD` 以 `latest` 头回带实际文件名（对标 sashub `SnapshotWS`）——
         本地没有带时间戳的构建时不拦截，按普通文件继续；
      2. 本地已有则直接发文件；
      3. 本地缺失时按 uri 选上游回源（`GavRepo.upstreamsFor`）：SNAPSHOT 只走 `<snapshot remote=...>`，
         其余走 `<maven><remote>`；未配置对应上游即 404。只回源文件型路径，目录型 URL 不探测上游。

      缓存策略沿用 `mavenArtifactCachePolicy`：`maven-metadata.xml*` 为 `public, no-cache`，
      快照构件（路径含 SNAPSHOT）为 `no-store`——同一路径可能被重新发布覆盖。
  */
  void service(HTTPServerRequest req, HTTPServerResponse res) {
    const uri = getResourceUri(endpoint, req);
    const ruri = repositoryUri(uri);

    auto latest = snapshots.latestAlias(ruri);
    if (latest !is null) {
      res.headers["latest"] = baseName(latest);
      if (req.method == HTTPMethod.HEAD) {
        res.statusCode = HTTPStatus.ok;
        res.writeVoidBody();
        return;
      }
      res.redirect(endpoint ~ latest);
      return;
    }

    auto file = repositoryPath(repo.base, uri);

    FileInfo fi;
    try
      fi = getFileInfo(file);
    catch (Exception) {
      // 本地缺失：`.diff` 与目录型 URL 直接 404；文件型按 uri 选上游拉取后发送
      // （SNAPSHOT 走 <snapshot remote>，其余走 <maven><remote>；未配置上游的列表为空，fetch 自然失败）。
      if (ruri.endsWith(".diff")) {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
      if (ruri.endsWith("/") || !looksLikeMavenArtifactFile(ruri)) {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
      if (repo.fetch(ruri)) {
        FileInfo ffi;
        try
          ffi = getFileInfo(file);
        catch (Exception)
          throw new HTTPStatusException(HTTPStatus.notFound);
        auto info = IndexedFileInfo.fromFileInfo(ffi);
        sendFile(req, res, file, info, mavenArtifactCachePolicy(ruri));
      } else {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
      return;
    }

    if (fi.isDirectory) {
      if (req.method == HTTPMethod.HEAD) {
        throw new HTTPStatusException(HTTPStatus.methodNotAllowed);
      }
      if (uri.slashEnded) {
        auto listData = genListContents(file, endpoint, ruri);
        render!("index.dt", listData)(res);
      } else {
        // 缺尾斜杠的目录（含仓库根 `/maven`）：补 `/` 后重定向，保证列表页的相对链接不倒挂
        res.redirect(directoryUri(endpoint, uri));
      }
    } else {
      auto info = IndexedFileInfo.fromFileInfo(fi);
      sendFile(req, res, file, info, mavenArtifactCachePolicy(ruri));
    }
  }
}
