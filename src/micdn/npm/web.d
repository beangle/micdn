/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.npm.web;
/// NPM 仓库浏览 HTTP 服务，提供本地 npm-repo 目录列表与文件下载。

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
import micdn.npm;
import micdn.web;
import micdn.web.file;
import micdn.web.server;

class NpmService {
  private const string endpoint;
  private const NpmRepo repo;

  this(MicdnConfig config) {
    this.endpoint = config.npm.endpoint;
    this.repo = NpmRepo.build(config);
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto uri = getPath(endpoint, req);
    if (uri.indexOf("..") > -1)
      throw new HTTPStatusException(HTTPStatus.notFound);

    import vibe.textfilter.urlencode;

    auto path = urlDecode(repo.base ~ uri);
    if (exists(path)) {
      if (isDir(path)) {
        if (uri.endsWith("/")) {
          auto listData = genListContents(repo.base ~ uri, endpoint, uri);
          render!("index.dt", listData)(res);
        } else {
          uri = endpoint ~ uri;
          res.redirect(req.requestURI.replace(uri, uri ~ "/"));
        }
      } else {
        sendFile(req, res, path);
      }
    } else {
      throw new HTTPStatusException(HTTPStatus.notFound);
    }
  }
}
