module beangle.web;
import vibe.http.server;

import std.string;

string getPath(string contextPath,HTTPServerRequest req){
  auto uri=req.requestURI;
  if (uri.startsWith( contextPath)){
    uri = uri[contextPath.length .. $];
  }else {
    throw new HTTPStatusException( HTTPStatus.NotFound);
  }
  auto qIdx=uri.indexOf( "?");
  if (qIdx >0){
    return uri[0..qIdx];
  }else {
    return uri;
  }
}
