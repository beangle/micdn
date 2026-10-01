/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.web.origin_test;

import std.typecons : tuple;

import vibe.http.common : HTTPMethod;
import vibe.http.server : createTestHTTPServerRequest;
import vibe.inet.message : InetHeaderMap;
import vibe.inet.url : URL;

import micdn.web.origin : getOrigin, isHttps, splitHostPort;

@("splitHostPort keeps IPv6 brackets and rejects bad ports")
unittest {
  assert(splitHostPort("cdn.example.com") == tuple("cdn.example.com", -1));
  assert(splitHostPort("cdn.example.com:8443") == tuple("cdn.example.com", 8443));
  assert(splitHostPort(" cdn.example.com:8443 ") == tuple("cdn.example.com", 8443));
  assert(splitHostPort("[::1]:8080") == tuple("[::1]", 8080));
  assert(splitHostPort("[::1]") == tuple("[::1]", -1));
  assert(splitHostPort("::1") == tuple("::1", -1), "bracketed-only IPv6 cannot carry a port");
  assert(splitHostPort("cdn.example.com:abc") == tuple("cdn.example.com", -1));
  assert(splitHostPort("cdn.example.com:70000") == tuple("cdn.example.com", -1));
  assert(splitHostPort("") == tuple("", -1));
}

@("getOrigin derives the origin from Host and the TLS state")
unittest {
  InetHeaderMap headers;
  headers["Host"] = "cdn.example.com";
  auto req = createTestHTTPServerRequest(URL("http://cdn.example.com/npm/a"), HTTPMethod.GET, headers, null);
  assert(getOrigin(req) == "http://cdn.example.com");

  // 端口按 Host 自带值；协议默认端口（80/443）省略
  headers["Host"] = "cdn.example.com:8443";
  req = createTestHTTPServerRequest(URL("http://cdn.example.com/npm/a"), HTTPMethod.GET, headers, null);
  assert(getOrigin(req) == "http://cdn.example.com:8443");

  headers["Host"] = "cdn.example.com:80";
  req = createTestHTTPServerRequest(URL("http://cdn.example.com/npm/a"), HTTPMethod.GET, headers, null);
  assert(getOrigin(req) == "http://cdn.example.com");

  // https 连接（URL schema 决定 tls）
  headers["Host"] = "cdn.example.com";
  req = createTestHTTPServerRequest(URL("https://cdn.example.com/npm/a"), HTTPMethod.GET, headers, null);
  assert(isHttps(req));
  assert(getOrigin(req) == "https://cdn.example.com");

  headers["Host"] = "cdn.example.com:443";
  req = createTestHTTPServerRequest(URL("https://cdn.example.com/npm/a"), HTTPMethod.GET, headers, null);
  assert(getOrigin(req) == "https://cdn.example.com");

  // IPv6 字面量保留方括号
  headers["Host"] = "[::1]:8080";
  req = createTestHTTPServerRequest(URL("http://[::1]:8080/npm/a"), HTTPMethod.GET, headers, null);
  assert(getOrigin(req) == "http://[::1]:8080");

  // 既无 Host 也无 X-Forwarded-Host：返回空串，由调用方兜底
  req = createTestHTTPServerRequest(URL("http://localhost/npm/a"), HTTPMethod.GET, InetHeaderMap.init, null);
  assert(getOrigin(req) == "");
}

@("getOrigin prefers X-Forwarded-* headers from a reverse proxy")
unittest {
  InetHeaderMap headers;
  headers["Host"] = "10.0.0.5:8888";
  headers["X-Forwarded-Host"] = "pub.example.com";
  headers["X-Forwarded-Proto"] = "https";
  auto req = createTestHTTPServerRequest(URL("http://10.0.0.5:8888/npm/a"), HTTPMethod.GET, headers, null);
  assert(getOrigin(req) == "https://pub.example.com");

  // X-Forwarded-Port 兜底（X-Forwarded-Host 不带端口）
  headers["X-Forwarded-Port"] = "8443";
  req = createTestHTTPServerRequest(URL("http://10.0.0.5:8888/npm/a"), HTTPMethod.GET, headers, null);
  assert(getOrigin(req) == "https://pub.example.com:8443");

  // 协议大小写不敏感
  headers["X-Forwarded-Proto"] = "HTTPS";
  req = createTestHTTPServerRequest(URL("http://10.0.0.5:8888/npm/a"), HTTPMethod.GET, headers, null);
  assert(getOrigin(req) == "https://pub.example.com:8443");

  // Host 自带端口优先于 X-Forwarded-Port（nginx $http_host vs $host）
  headers["X-Forwarded-Host"] = "pub.example.com:9443";
  req = createTestHTTPServerRequest(URL("http://10.0.0.5:8888/npm/a"), HTTPMethod.GET, headers, null);
  assert(getOrigin(req) == "https://pub.example.com:9443");

  // 端口非法则忽略，退回协议默认端口
  headers["X-Forwarded-Host"] = "pub.example.com";
  headers["X-Forwarded-Port"] = "not-a-port";
  headers["X-Forwarded-Proto"] = "http";
  req = createTestHTTPServerRequest(URL("http://10.0.0.5:8888/npm/a"), HTTPMethod.GET, headers, null);
  assert(getOrigin(req) == "http://pub.example.com");
}
