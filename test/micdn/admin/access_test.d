/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.admin.access_test;

import micdn.admin.access;

@("admin isLocalhostPeer accepts loopback with port")
unittest {
  assert(isLocalhostPeer("127.0.0.1"));
  assert(isLocalhostPeer("127.0.0.1:8080"));
  assert(isLocalhostPeer("::ffff:127.0.0.1:53556"));
  assert(isLocalhostPeer("::1"));
  assert(!isLocalhostPeer("192.168.1.1"));
  assert(!isLocalhostPeer(""));
}
