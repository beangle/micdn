module micdn.asset.web;
/// 静态资源服务入口，挂载资源上下文并提供 HTTP 访问。

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

import micdn.asset;
import micdn.model;
import micdn.web;
import micdn.web.file;
import micdn.web.filebrowser;
import micdn.web.server;
import micdn.xml;

class AssetService {
  private const string endpoint;
  private const AssetRepo repo;

  this(MicdnConfig config) {
    this.endpoint = config.asset.endpoint;
    this.repo = AssetRepo.build(config);
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto uri = getPath(endpoint, req);
    auto rs = repo.get(uri);
    if (null == rs) {
      throw new HTTPStatusException(HTTPStatus.notFound);
    } else {
      // dir
      if (isDir(rs[0])) {
        if (repo.publicList) {
          if (uri.endsWith("/")) {
            auto content = genListContents(repo.base ~ uri, endpoint, uri);
            render!("index.dt", uri, content)(res);
          } else {
            uri = endpoint ~ uri;
            res.redirect(req.requestURI.replace(uri, uri ~ "/"));
          }
        } else {
          throw new HTTPStatusException(HTTPStatus.notFound);
        }
      } else {
        void setCORS(scope HTTPServerRequest req, scope HTTPServerResponse res,
            ref string physicalPath) @safe {
          res.headers["Access-Control-Allow-Origin"] = "*";
        }

        auto settings = new CacheSetting;
        settings.preWriteCallback = &setCORS;

        if (rs.length == 1) {
          sendFile(req, res, rs[0], settings);
        } else {
          sendFiles(req, res, rs, settings);
        }
      }
    }
  }
}
