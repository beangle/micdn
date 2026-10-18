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
import micdn.remote : parseRemoteConfig, remoteConfigPath;

@("micdn.conf parses [remote] url and token")
unittest {
  auto rc = parseRemoteConfig(`[remote]
url = http://cfg.example.com/micdn.xml
token = s3cret
`);
  assert(rc.active);
  assert(rc.url == "http://cfg.example.com/micdn.xml");
  assert(rc.token == "s3cret");
}

@("micdn.conf accepts https, quoted values and unrelated keys")
unittest {
  auto rc = parseRemoteConfig(`[other]
retries = 3

[REMOTE]
URL = "https://cfg.example.com/micdn.xml"
token = 'a-b.c_d~e+f/g='
`);
  assert(rc.url == "https://cfg.example.com/micdn.xml");
  assert(rc.token == "a-b.c_d~e+f/g=");
}

@("micdn.conf only accepts http/https and a header-safe token")
unittest {
  assertThrown!Exception(parseRemoteConfig("[remote]\nurl = file:///etc/micdn.xml\n"));
  assertThrown!Exception(parseRemoteConfig("[remote]\nurl = ftp://cfg/micdn.xml\n"));
  assertThrown!Exception(parseRemoteConfig("[remote]\nurl = http://cfg/micdn.xml\ntoken = a b\n"));
  assertThrown!Exception(parseRemoteConfig("[remote]\nurl = http://cfg/micdn.xml\ntoken = a,b\n"));
  assertThrown!Exception(parseRemoteConfig("url = http://cfg/micdn.xml\n"));
}

@("micdn.conf sits next to micdn.xml")
unittest {
  assert(remoteConfigPath("/etc/micdn/micdn.xml") == "/etc/micdn/micdn.conf");
}

@("micdn.xml rejects the retired remote attribute")
unittest {
  assertThrown!Exception(parse("/tmp", `<micdn remote="http://cfg.example.com/micdn.xml"></micdn>`));
}
