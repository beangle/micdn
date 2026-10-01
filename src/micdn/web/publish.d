/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.web.publish;
/** 发布（上传）端点的公共支持：令牌校验与请求体读取。

    发布端点（npm 的 `PUT /npm/{pkg}`、maven 的 `PUT /maven/{path}`）**只在配置了
    `<publish token="…"/>` 时挂载**，每次上传都必须携带与配置一致的令牌。

    **为什么以令牌而非对端地址作为写权限凭据**：对端地址在本机反代（如 HAProxy 绑 `0.0.0.0`
    转发到 `127.0.0.1:8080`）下必然失效——远端请求由代理以环回源地址转发，TCP 模式也不留下任何
    可区分的标记。反过来，令牌本来就与来源无关：前端开发机可以带令牌直接推给远端 micdn（npm 的
    `_authToken`、Maven `settings.xml` 的 server 凭据都会走 `Authorization`），因此不再限制对端接口。
    代价是令牌等同写权限：**只应经 HTTPS（或反向代理的 HTTPS 终止）暴露发布端点**，并选用足够长的
    随机令牌——明文 HTTP 会把 Bearer 凭据暴露在链路上。
*/

import eventcore.driver : IOMode;

import std.base64;
import std.array : replicate;
import std.string : icmp, indexOf, strip;

import vibe.core.stream : InputStream;
import vibe.http.common : HTTPStatus;
import vibe.http.server;

/// 令牌缺失/不符时的挑战：Maven 收到 401 后才会带 `settings.xml` 的凭据重试。
private enum wwwAuthenticateChallenge = `Basic realm="micdn"`;

/** 发布授权：校验令牌（不符/缺失 401，并给出 Basic 挑战）。

    返回 false 时已写好完整响应，调用方直接 return 即可（不要再写 body）。
*/
bool authorizePublish(scope HTTPServerRequest req, scope HTTPServerResponse res, string token) {
  if (token.length > 0
      && tokenAccepted(token, req.headers.get("X-Micdn-Token", ""),
          req.headers.get("Authorization", "")))
    return true;
  res.headers["WWW-Authenticate"] = wwwAuthenticateChallenge;
  res.statusCode = HTTPStatus.unauthorized;
  res.writeBody("publish requires a token (Authorization: Bearer/Basic or X-Micdn-Token)",
      "text/plain; charset=utf-8");
  return false;
}

/** 从 `X-Micdn-Token` 与 `Authorization` 头解析令牌。`expected` 为空表示未启用发布，一律拒绝。

    `Authorization` 支持 `Bearer <token>`（npm）与 `Basic <base64>`（Maven 的 `user:password`）；
    Basic 解出的用户名或口令任一同令牌即算通过（不同客户端把令牌放在哪一侧的做法不一致）。
*/
bool tokenAccepted(const(char)[] expected, const(char)[] xToken, const(char)[] authorization) {
  if (expected.length == 0)
    return false;
  if (secureEquals(strip(xToken), expected))
    return true;

  auto auth = strip(authorization);
  if (auth.length > 7 && icmp(auth[0 .. 6], "Bearer") == 0 && auth[6] == ' ')
    return secureEquals(strip(auth[7 .. $]), expected);
  if (auth.length > 6 && icmp(auth[0 .. 5], "Basic") == 0 && auth[5] == ' ') {
    ubyte[] decoded;
    try
      decoded = decodeBase64Loose(strip(auth[6 .. $]));
    catch (Exception)
      return false;
    auto text = cast(string) decoded;
    auto colon = text.indexOf(':');
    if (colon < 0)
      return secureEquals(text, expected);
    return secureEquals(text[0 .. colon], expected) || secureEquals(text[colon + 1 .. $], expected);
  }
  return false;
}

/// 定长时间比较，避免按字节比较泄露令牌前缀长度；长度不同直接判否。
bool secureEquals(const(char)[] a, const(char)[] b) {
  if (a.length != b.length)
    return false;
  ubyte diff;
  foreach (i; 0 .. a.length)
    diff |= cast(ubyte)(a[i] ^ b[i]);
  return diff == 0;
}

/// 宽松解码 Base64（容许缺少 `=` 填充；各客户端行为不尽一致）。
ubyte[] decodeBase64Loose(const(char)[] encoded) {
  char[] text = encoded.dup;
  auto pad = (4 - text.length % 4) % 4;
  if (pad == 3)
    throw new Exception("not valid base64");
  if (pad > 0)
    text ~= "=".replicate(pad);
  try
    return Base64.decode(text);
  catch (Exception e)
    throw new Exception("not valid base64: " ~ e.msg);
}

/** 读取整个请求体，最多 `maxSize` 字节（超出抛 413）。

    必须「先判 `empty` 再 `read`」：vibe-http 把请求体包成 `LimitedHTTPInputStream`，
    流已到末尾时再 read 会抛 413。这里按 `beangle-d-web` 技能的第三种写法实现
    （`micdn/blob/s3.d` 里的 `IOMode.all` 循环是反例，勿抄）。
*/
ubyte[] readUploadBody(InputStream input, size_t maxSize) {
  ubyte[] buffer = new ubyte[64 * 1024];
  ubyte[] total;
  while (!input.empty) {
    auto n = input.read(buffer, IOMode.once);
    if (n == 0)
      break;
    if (total.length + n > maxSize)
      throw new HTTPStatusException(HTTPStatus.requestEntityTooLarge, "upload too large");
    total ~= buffer[0 .. n];
  }
  return total;
}
