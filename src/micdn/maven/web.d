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
/// 正式版与 SNAPSHOT 共用 `/maven` 与同一仓库根，设计见 `docs/merged_repo.md`。

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

      SNAPSHOT 的 maven-metadata.xml 与别名另有两点：
      - 交付前按 TTL 从 `<snapshot remote>` 重新探测版本目录的元数据（`GavRepo.refreshSnapshotMetadata`），
        上游新 deploy 的构建才能在别名与元数据上可见；
      - artifact 级 maven-metadata.xml（`{group}/{artifact}/maven-metadata.xml`）若本地有 `*-SNAPSHOT`
        版本目录，则把本地快照版本并进 `<versions>`（`SnapshotRepo.mergeArtifactMetadata`），
        让 `LATEST` / 版本范围也能看到本地装入的开发版；纯正式版 artifact 的元数据原样透传。

      缓存策略沿用 `mavenArtifactCachePolicy`：`maven-metadata.xml*` 为 `public, no-cache`，
      快照构件（路径含 SNAPSHOT）为 `no-store`——同一路径可能被重新发布覆盖。
  */
  void service(HTTPServerRequest req, HTTPServerResponse res) {
    const uri = getResourceUri(endpoint, req);
    const ruri = repositoryUri(uri);

    // SNAPSHOT 元数据/别名：按 TTL 重新探测上游，让新构建可见（未配置 <snapshot remote> 时为空操作）
    repo.refreshSnapshotMetadata(ruri);

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
      // 上游拿不到时，artifact 级元数据仍可由本地快照版本目录生成（没有本地快照目录则 404）
      if (!repo.fetch(ruri) && snapshots.mergeArtifactMetadata(ruri) is null) {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
      try
        fi = getFileInfo(file);
      catch (Exception)
        throw new HTTPStatusException(HTTPStatus.notFound);
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
      // artifact 级元数据：把本地 SNAPSHOT 版本并进 <versions>（无本地快照目录时不改动）
      if (snapshots.mergeArtifactMetadata(ruri) !is null)
        try
          fi = getFileInfo(file);
        catch (Exception)
          throw new HTTPStatusException(HTTPStatus.notFound);
      auto info = IndexedFileInfo.fromFileInfo(fi);
      sendFile(req, res, file, info, mavenArtifactCachePolicy(ruri));
    }
  }
}
