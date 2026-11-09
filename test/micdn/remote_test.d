/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.remote_test;

import std.exception : assertThrown;

import micdn.config : parse;
import micdn.remote : parseRemoteEnvironment;

@("BAS_PRINCIPAL splits project and root url") unittest {
  auto rc = parseRemoteEnvironment("org.example@https://hub.example.com", "s3cret");
  assert(rc.active);
  assert(rc.url == "https://hub.example.com");
  assert(rc.project == "org.example");
  assert(rc.token == "s3cret");
}

@("empty environment means local mode") unittest {
  assert(!parseRemoteEnvironment("", "").active);
}

@("remote environment requires both variables and a valid principal") unittest {
  assertThrown!Exception(parseRemoteEnvironment("", "token"));
  assertThrown!Exception(parseRemoteEnvironment("org.example@https://hub", ""));
  assertThrown!Exception(parseRemoteEnvironment("org.example", "token"));
  assertThrown!Exception(parseRemoteEnvironment("org/example@https://hub", "token"));
  assertThrown!Exception(parseRemoteEnvironment("org.example@ftp://hub", "token"));
  assertThrown!Exception(parseRemoteEnvironment("org.example@https://hub", "a b"));
}

@("micdn.xml rejects the retired remote attribute") unittest {
  assertThrown!Exception(parse("/tmp", `<micdn remote="http://cfg.example.com/micdn.xml"></micdn>`));
}
