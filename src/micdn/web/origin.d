/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

module micdn.web.origin;
/// 请求 origin（`scheme://host[:port]`）推导，对标 Beangle `RequestUtils.getOrigin`。

import std.conv : to;
import std.string;
import std.typecons : Tuple, tuple;

import vibe.http.server : HTTPServerRequest;

/** 返回请求的 origin，形如 `scheme://host[:port]`；协议默认端口（http 80 / https 443）省略。

    反向代理场景取浏览器看到的那一侧，与 Beangle `RequestUtils.getOrigin` 同口径：
    协议优先 `X-Forwarded-Proto: https`（其次看连接本身是否 TLS），主机优先 `X-Forwarded-Host`
    （其次 `Host`，容器保留原样不解析），端口优先 `Host` 自带端口，其次 `X-Forwarded-Port`
    （nginx `$host` 不带端口、`$http_host` 带，自带端口优先，与 Undertow `ProxyPeerAddressHandler` 一致）。

    与 Scala 版的差异：vibe 不暴露监听端口（Servlet 的 `getServerPort`），端口取不到时按协议默认端口省略。
    拿不到主机名（既无 Host 也无 `X-Forwarded-Host`）时返回空串；调用方按「原样输出」处理（包名路径无 Host 的请求
    本身已属异常，不猜地址）。
*/
string getOrigin(ref const HTTPServerRequest req) {
  auto hostPort = req.headers.get(headerForwardedHost, "").strip;
  if (hostPort.length == 0)
    hostPort = req.host is null ? "" : req.host.strip;
  auto parsed = splitHostPort(hostPort);
  if (parsed[0].length == 0)
    return "";

  auto scheme = isHttps(req) ? "https" : "http";
  auto port = parsed[1];
  if (port <= 0) {
    auto forwardedPort = req.headers.get(headerForwardedPort, "").strip;
    port = parsePort(forwardedPort);
  }

  auto origin = scheme ~ "://" ~ parsed[0];
  auto defaultPort = scheme == "https" ? 443 : 80;
  if (port > 0 && port != defaultPort)
    origin ~= ":" ~ port.to!string;
  return origin;
}

/// 请求是否 HTTPS：连接本身 TLS，或反向代理声明 `X-Forwarded-Proto: https`（大小写不敏感）。
bool isHttps(ref const HTTPServerRequest req) {
  if (req.tls)
    return true;
  return icmp(req.headers.get(headerForwardedProto, "").strip, "https") == 0;
}

/** 拆分 `host[:port]`，返回 (host, port)；无端口返回 -1，非法端口同样返回 -1。

    IPv6 字面量保留方括号（`[::1]:8080` → `[::1]` + 8080；裸 `::1` 无方括号无法定端口，整体作 host）。
*/
Tuple!(string, int) splitHostPort(string hostPort) {
  auto value = hostPort.strip;
  if (value.startsWith("[")) {
    auto close = value.indexOf(']');
    if (close < 0)
      return tuple(value, -1);
    auto portText = value[close + 1 .. $].stripLeft(":");
    return tuple(value[0 .. close + 1], parsePort(portText));
  }
  auto colon = value.lastIndexOf(':');
  if (colon < 0 || colon != value.indexOf(':'))
    return tuple(value, -1);
  return tuple(value[0 .. colon], parsePort(value[colon + 1 .. $]));
}

/** 解析端口文本，非纯数字或超出 1..65535 返回 -1（无端口）。

    不用 `to!int(text, -1)`：本机 Phobos 没有该 fallback 重载，会走到 `to` 的断言里（实测直接崩线程）。
*/
private int parsePort(string text) {
  auto t = text.strip;
  if (t.length == 0 || t.length > 5)
    return -1;
  foreach (c; t) {
    if (c < '0' || c > '9')
      return -1;
  }
  auto n = to!int(t);
  return n <= 65535 ? n : -1;
}

/// `X-Forwarded-Proto`：代理声明的原始协议。
private enum string headerForwardedProto = "X-Forwarded-Proto";
/// `X-Forwarded-Host`：代理声明的原始主机（可能自带端口）。
private enum string headerForwardedHost = "X-Forwarded-Host";
/// `X-Forwarded-Port`：代理声明的原始端口。
private enum string headerForwardedPort = "X-Forwarded-Port";
