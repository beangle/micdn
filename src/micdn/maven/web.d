module micdn.maven.web;
/// Maven 代理 HTTP 服务入口，转发并缓存上游 Maven 仓库。

import std.exception;
import std.file;
import std.stdio;
import std.string;

import vibe.core.core;
import vibe.core.file;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.web.web;

import micdn.maven;
import micdn.model;
import micdn.web;
import micdn.web.file;
import micdn.web.filebrowser;
import micdn.web.server;
import micdn.xml;

class MavenService {
  private const string endpoint;
  private const GavRepo repo;

  this(MicdnConfig config) {
    this.endpoint = config.maven.endpoint;
    this.repo = GavRepo.build(config);
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto uri = getPath(endpoint, req);
    if (uri.indexOf("..") > -1)
      throw new HTTPStatusException(HTTPStatus.notFound);

    import vibe.textfilter.urlencode;

    auto file = urlDecode(repo.base ~ uri);
    if (exists(file)) {
      if (isDir(file)) {
        if (repo.publicList) {
          if (uri.endsWith("/")) {
            auto content = genListContents(repo.base ~ uri, endpoint, uri);
            render!("index.dt", uri, content)(res);
          } else {
            uri = endpoint ~ uri;
            res.redirect(req.requestURI.replace(uri, uri ~ "/"));
          }
        } else {
          throw new HTTPStatusException(HTTPStatus.forbidden);
        }
      } else {
        sendFile(req, res, file);
      }
    } else {
      if (uri.endsWith(".diff")) {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
      if (repo.fetch(uri)) {
        sendFile(req, res, file);
      } else {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
    }
  }
}
