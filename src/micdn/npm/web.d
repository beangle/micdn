/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.npm.web;
/// NPM 仓库浏览 HTTP 服务，提供本地npm目录列表与文件下载。

import std.algorithm;
import std.exception;
import std.string;

import vibe.core.core;
import vibe.core.file;
import vibe.http.router;
import vibe.http.server;
import vibe.web.web;

import micdn.fs.browser;
import micdn.model;
import micdn.routes;
import micdn.npm;
import micdn.web;
import micdn.web.cache;
import micdn.web.file;

class NpmService {
  private enum string endpoint = mountNpm;
  private const NpmRepo repo;

  this(MicdnConfig config) {
    this.repo = NpmRepo.build(config);
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    const uri = getPath(endpoint, req);
    auto path = resolveRepositoryPath(repo.base, uri);
    if (path is null)
      throw new HTTPStatusException(HTTPStatus.notFound);

    // 支持 NPM 官方 tgz URL：{packageName}/-/{name}-{version}.tgz，不存在则下载后返回
    if (uri.canFind("/-/") && uri.endsWith(".tgz")) {
      auto parsed = parseTarballUri(uri);
      if (parsed[0]!is null && parsed[1]!is null && parsed[2]!is null) {
        if (repo.fetch(parsed[0], parsed[1], parsed[2])) {
          auto local = repo.localTarball(parsed[0], parsed[1], parsed[2]);
          FileInfo tfi;
          try
            tfi = getFileInfo(local);
          catch (Exception)
            throw new HTTPStatusException(HTTPStatus.notFound);
          sendFile(req, res, local, tfi, npmArtifactCachePolicy(), null, false);
          return;
        }
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
    }

    FileInfo fi;
    try
      fi = getFileInfo(path);
    catch (Exception)
      // 本地缺失（含 tgz 未命中缓存）直接 404，不做目录列表。
      throw new HTTPStatusException(HTTPStatus.notFound);

    if (fi.isDirectory) {
      if (req.method == HTTPMethod.HEAD) {
        throw new HTTPStatusException(HTTPStatus.methodNotAllowed);
      }
      if (uri.endsWith("/")) {
        auto listData = genListContents(path, endpoint, uri);
        render!("index.dt", listData)(res);
      } else {
        auto pub = endpoint ~ uri;
        res.redirect(req.requestURI.replace(pub, pub ~ "/"));
      }
    } else {
      sendFile(req, res, path, fi, npmArtifactCachePolicy(), null, false);
    }
  }
}
