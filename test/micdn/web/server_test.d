module test.micdn.web.server_test;

import std.file;
import std.path;
import micdn.web.server;

@("web server parse config")
unittest {
  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<Server ips="192.168.31.244" port="8081">
  <Context path="/blob" />
</Server>`;
  auto server = ServerOptions.parse(content);
  assert(server.ips.length == 1);

  string test = "~/ems/micdn/asset.xml";
  assert(dirName(test) == "~/ems/micdn");
}
