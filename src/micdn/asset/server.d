module micdn.asset.server;

import std.stdio;
import std.file;
import std.string;
import std.exception;
import vibe.core.core;
import vibe.core.log;
import vibe.core.file;
import vibe.http.router;
import vibe.http.server;
import vibe.web.web;
import micdn.web;
import micdn.web.file;
import micdn.web.filebrowser;
import micdn.web.server;
import micdn.asset.repository;
import micdn.asset.config;

private class AssetServer {
  const string home;
  const ServerOptions options;
  const Config config;
  const Repository repository;
  this(string home, ServerOptions options, Config config, Repository repository) {
    this.home = home;
    this.options = options;
    this.config = config;
    this.repository = repository;
  }
}

AssetServer server;

void assertStart(string home, ServerOptions options, string configFile) {
  auto config = Config.parse(home, readXml(configFile));
  auto repository = Repository.build(config);
  server = new AssetServer(home, options, config, repository);

  auto router = new URLRouter(server.options.contextPath);
  router.get("*", &index);

  auto settings = new HTTPServerSettings;
  settings.bindAddresses = server.options.ips.dup;
  settings.port = server.options.port;
  settings.serverString = null;

  listenHTTP(settings, router);
  logInfo("Micdn asset was started on http://" ~ server.options.listenAddr ~ server.options.contextPath);
  runApplication(&args);
}

void index(HTTPServerRequest req, HTTPServerResponse res) {
  auto uri = getPath(server.options.contextPath, req);
  if (uri == "/config.xml") {
    res.statusCode = 200;
    res.headers["Content-Type"] = "application/xml";
    res.writeBody(server.config.toXml());
  } else {
    auto rs = server.repository.get(uri);
    if (null == rs) {
      throw new HTTPStatusException(HTTPStatus.notFound);
    } else {
      // dir
      if (isDir(rs[0])) {
        if (server.config.publicList) {
          if (uri.endsWith("/")) {
            auto content = genListContents(server.repository.base ~ uri, server.options.contextPath, uri);
            render!("index.dt", uri, content)(res);
          } else {
            uri = server.options.contextPath ~ uri;
            res.redirect(req.requestURI.replace(uri, uri ~ "/"));
          }
        } else {
          throw new HTTPStatusException(HTTPStatus.notFound);
        }
      } else {
        void setCORS(scope HTTPServerRequest req, scope HTTPServerResponse res, ref string physicalPath) @safe {
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
