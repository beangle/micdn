/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.admin.access;
/// admin 只读接口的 localhost 访问校验。

import std.string : startsWith;

import vibe.http.server;

void requireLocalhostPeer(scope HTTPServerRequest req) {
  if (!isLocalhostPeer(req.peer))
    throw new HTTPStatusException(HTTPStatus.forbidden,
        "admin read endpoints only allowed from localhost");
}

bool isLocalhostPeer(string peer) {
  if (peer.length == 0)
    return false;
  if (peer == "127.0.0.1" || peer.startsWith("127.0.0.1:"))
    return true;
  if (peer == "::1" || peer.startsWith("::1:"))
    return true;
  if (peer.startsWith("[::1]"))
    return true;
  if (peer.startsWith("::ffff:127.0.0.1"))
    return true;
  return false;
}
