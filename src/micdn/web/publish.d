/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.web.publish;
/** `/maven`、`/npm`、`/native` 的访问控制与上传公共支持：令牌校验、请求体读取与按路径原子落盘。

    配置来自 `<auth publish-key="…" download-key="…" max-size="…"/>`（见 `micdn.model.AuthConfig`）：
    - 写（PUT）：`publishKey` 非空才挂载上传端点（npm 的 `PUT /npm/{pkg}`、maven 的
      `PUT /maven/{path}`、native 的 `PUT /native/{path}`），每次上传都必须携带它；
    - 读（GET）：`downloadKey` **可选**，为空时不认证（默认，与引入本元素之前一致）；非空时
      「会写出文件体的 GET」必须携带它，而 `HEAD`、目录列表与 302 不设限（见 `authorizeRead`）。

    **为什么以令牌而非对端地址作为写权限凭据**：对端地址在本机反代（如 HAProxy 绑 `0.0.0.0`
    转发到 `127.0.0.1:8080`）下必然失效——远端请求由代理以环回源地址转发，TCP 模式也不留下任何
    可区分的标记。反过来，令牌本来就与来源无关：前端开发机可以带令牌直接推给远端 micdn（npm 的
    `_authToken`、Maven `settings.xml` 的 server 凭据都会走 `Authorization`），因此不再限制对端接口。
    代价是密钥等同权限：**只应经 HTTPS（或反向代理的 HTTPS 终止）暴露这些端点**，并选用足够长的
    随机串——明文 HTTP 会把 Bearer 凭据暴露在链路上。
*/

import eventcore.driver : IOMode;

import std.algorithm.searching : any;
import std.algorithm : endsWith;
import std.base64;
import std.array : replicate;
import std.file;
import std.path : dirName;
import std.string : icmp, indexOf, split, strip;

import vibe.core.stream : InputStream;
import vibe.http.common : HTTPStatus;
import vibe.http.server;

/// 令牌缺失/不符时的挑战：Maven 收到 401 后才会带 `settings.xml` 的凭据重试。
private enum wwwAuthenticateChallenge = `Basic realm="micdn"`;

/** 写授权（PUT）：校验上传令牌（不符/缺失 401，并给出 Basic 挑战）。

    返回 false 时已写好完整响应，调用方直接 return 即可（不要再写 body）。
*/
bool authorizeWrite(scope HTTPServerRequest req, scope HTTPServerResponse res, string publishKey) {
  if (publishKey.length > 0 && tokenAccepted(publishKey, req.headers.get("X-Micdn-Token", ""),
      req.headers.get("Authorization", "")))
    return true;
  res.headers["WWW-Authenticate"] = wwwAuthenticateChallenge;
  res.statusCode = HTTPStatus.unauthorized;
  res.writeBody("publish requires a token (Authorization: Bearer/Basic or X-Micdn-Token)",
      "text/plain; charset=utf-8");
  return false;
}

/** 读授权：受 `downloadKey` 保护的请求（见 `readNeedsToken`）凭据不符时写 401 并返回 false；
    未配置 `downloadKey`、`HEAD`、目录型 URI 一律放行。

    **判定在触碰文件系统与上游之前完成**：未授权请求既不会触发回源/落盘，也不会因为
    404 与 401 的差异暴露某个路径是否存在。

    挑战沿用写路径的 `Basic realm="micdn"`：Maven 收到 401 后才会带 `settings.xml` 的
    server 凭据重试；npm 则对匹配的 registry 预置 `_authToken`，不依赖挑战。
    401 带 `Cache-Control: no-store`，避免挑战本身被缓存下来。
*/
bool authorizeRead(scope HTTPServerRequest req, scope HTTPServerResponse res,
    string downloadKey, string ruri) {
  if (!readNeedsToken(req, downloadKey, ruri))
    return true;
  if (tokenAccepted(downloadKey, req.headers.get("X-Micdn-Token", ""),
      req.headers.get("Authorization", "")))
    return true;
  res.headers["WWW-Authenticate"] = wwwAuthenticateChallenge;
  res.headers["Cache-Control"] = "no-store";
  res.statusCode = HTTPStatus.unauthorized;
  res.writeBody("download requires a token (Authorization: Bearer/Basic or X-Micdn-Token)",
      "text/plain; charset=utf-8");
  return false;
}

/** 本次请求是否需要下载凭据：配置了 `downloadKey`，且是「会写出文件体」的 GET。

    `HEAD` 与以 `/` 结尾的 URI（目录列表）不设限，理由：
    - `HEAD` 是客户端探测存在性的常规手段——boot 的 `Repo.Remote.exists`（`HttpUtils.isAlive`）走
      HEAD，jstart 用 `curl -I -L` 探测增量补丁；一旦要求凭据，这些探测（以及镜像选择）全部失效；
    - 目录列表只暴露「有什么」，不交出构件字节。
    代价是仓库内容（包名、版本、文件名、大小）对未授权者可见，`downloadKey` 保护的是字节本身。

    服务端用同一判定的结果决定缓存策略（受限响应降级为 `private`，见 `micdn.web.cache.gatedPolicy`）。
*/
bool readNeedsToken(scope HTTPServerRequest req, string downloadKey, string ruri) {
  if (downloadKey.length == 0)
    return false;
  if (req.method != HTTPMethod.GET)
    return false;
  return !ruri.endsWith("/");
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

/** 把上传体原子写入 `base + ruri`，返回落盘绝对路径；路径非法时抛异常。

    服务端不解析、不重写上传内容——`mvn deploy` 自己生成时间戳文件名与 `maven-metadata.xml`，
    native 的 tar.gz/增量补丁同样按客户端给的路径原样落盘，因此读路径（快照别名解析、元数据合并、
    目录列表）拿到的就是客户端写的那一份。`ruri` 一般来自 `repositoryUri(ResourceUri.segs)`（已消解
    点段），这里再防一手直接调用方。

    写入方式与仓库其余写入一致（元数据/上游下载）：先写同目录 `.incoming` 临时文件，再 rename
    原子替换。同路径重复上传按覆盖处理（开发版构件本来就会反复重发）。
*/
string storeUpload(string base, string ruri, const(ubyte)[] body) {
  if (ruri.length == 0 || ruri == "/" || ruri.endsWith("/"))
    throw new Exception("publish requires a file path: " ~ ruri);
  if (ruri.split("/").any!(seg => seg == ".." || seg == "."))
    throw new Exception("publish rejects dot segments: " ~ ruri);

  auto path = base ~ ruri;
  mkdirRecurse(dirName(path));
  auto tmp = path ~ ".incoming";
  scope (failure)
    if (exists(tmp))
      remove(tmp);
  std.file.write(tmp, body);
  rename(tmp, path);
  return path;
}
