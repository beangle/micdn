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
import std.file;
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
import micdn.web.server;

class NpmService {
  private enum string endpoint = mountNpm;
  private const NpmRepo repo;

  this(MicdnConfig config) {
    this.repo = NpmRepo.build(config);
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto uri = getPath(endpoint, req);
    auto decodedUri = decodeRepositoryUri(uri);
    auto path = resolveRepositoryPath(repo.base, decodedUri);
    if (path is null)
      throw new HTTPStatusException(HTTPStatus.notFound);

    // 支持 NPM 官方 tgz URL：{packageName}/-/{name}-{version}.tgz，不存在则下载后返回
    if (decodedUri.canFind("/-/") && decodedUri.endsWith(".tgz")) {
      auto parsed = parseTarballUri(decodedUri);
      if (parsed[0]!is null && parsed[1]!is null && parsed[2]!is null) {
        if (repo.fetch(parsed[0], parsed[1], parsed[2])) {
          auto local = repo.localTarball(parsed[0], parsed[1], parsed[2]);
          sendFile(req, res, local, npmArtifactCachePolicy());
          return;
        }
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
    }

    if (exists(path)) {
      if (isDir(path)) {
        if (req.method == HTTPMethod.HEAD) {
          throw new HTTPStatusException(HTTPStatus.methodNotAllowed);
        }
        if (decodedUri.endsWith("/")) {
          auto listData = genListContents(path, endpoint, decodedUri);
          render!("index.dt", listData)(res);
        } else {
          auto pub = endpoint ~ decodedUri;
          res.redirect(req.requestURI.replace(pub, pub ~ "/"));
        }
      } else {
        sendFile(req, res, path, npmArtifactCachePolicy());
      }
    } else {
      throw new HTTPStatusException(HTTPStatus.notFound);
    }
  }
}
