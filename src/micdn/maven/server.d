module micdn.maven.server;

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
import micdn.maven.config;
import micdn.xml.reader;

private class MavenServer {
  const ServerOptions options;
  const Config config;
  this(ServerOptions options, Config config) {
    this.options = options;
    this.config = config;
  }
}

MavenServer server;

void mavenStart(ServerOptions options, string configFile) {
  auto config = Config.parse("~/.m2/repository", readXml(configFile));
  mkdirRecurse(config.base);
  server = new MavenServer(options, config);
  auto router = new URLRouter(server.options.contextPath);
  router.get("*", &index);

  auto settings = new HTTPServerSettings;
  settings.bindAddresses = server.options.ips.dup;
  settings.port = server.options.port;
  settings.serverString = null;

  listenHTTP(settings, router);
}

void index(HTTPServerRequest req, HTTPServerResponse res) {
  auto uri = getPath(server.options.contextPath, req);
  auto config = server.config;
  if (uri.indexOf("..") > -1)
    throw new HTTPStatusException(HTTPStatus.notFound);

  import vibe.textfilter.urlencode;

  auto file = urlDecode(config.base ~ uri);
  if (exists(file)) {
    if (isDir(file)) {
      if (config.publicList) {
        if (uri.endsWith("/")) {
          auto content = genListContents(config.base ~ uri, server.options.contextPath, uri);
          render!("index.dt", uri, content)(res);
        } else {
          uri = server.options.contextPath ~ uri;
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
    if (config.cacheable) {
      if (config.fetchArtifact(uri)) {
        sendFile(req, res, file);
      } else {
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
    } else {
      res.redirect(config.defaultRepo ~ uri);
    }
  }
}
