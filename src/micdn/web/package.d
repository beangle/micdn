module micdn.web;
/// web 子模块的聚合导出，简化 HTTP 相关导入。
import vibe.http.server;

import std.string;

string getPath(string contextPath, HTTPServerRequest req) {
  auto uri = req.requestURI;
  if (contextPath != "" && contextPath != "/") {
    if (uri.startsWith(contextPath)) {
      uri = uri[contextPath.length .. $];
    } else {
      throw new HTTPStatusException(HTTPStatus.notFound);
    }
  }
  auto qIdx = uri.indexOf("?");
  if (qIdx > 0) {
    return uri[0 .. qIdx];
  } else {
    return uri;
  }
}
