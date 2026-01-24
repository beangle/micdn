module micdn.main;
import std.stdio;
import std.file : getcwd, exists;
import std.algorithm : canFind;

import micdn.web.server;
import vibe.core.args;
import vibe.core.core;
import vibe.core.log;
import micdn.maven.server : mavenStart;
import micdn.asset.server : assetStart;
import micdn.blob.server : blobStart;

void main(string[] args) {
  if (args.length < 3) {
    writeln("Usage: " ~ args[0] ~ " --as maven --server path/to/server.xml --config path/to/config.xml");
    writeln("Usage: " ~ args[0] ~ " --as asset --server path/to/server.xml --config path/to/config.xml");
    writeln("Usage: " ~ args[0] ~ " --as blob --server path/to/server.xml --config path/to/config.xml");
    return;
  }

  string serverType;
  auto hasServer = readOption!string("as", &serverType, "Please specify --as params[maven|asset|blob]");
  auto servers = ["maven", "asset", "blob"];

  if (!hasServer || !(servers.canFind(serverType))) {
    writeln("Please specify --as params[maven|asset|blob]");
    return;
  } else {
    auto options = getServerOptions(serverType);
    auto hc = readConfig(getcwd(), serverType ~ ".xml");
    auto home = hc[0];
    auto config = hc[1];

    if (!exists(config)) {
      logError("Config file[" ~ config ~ "] not exists!");
      return;
    }
    writefln("Find config: %s", config);
    switch (serverType) {
    case "maven":
      mavenStart(options, config);
      break;
    case "asset":
      assetStart(home, options, config);
      break;
    case "blob":
      blobStart(home, options, config);
      break;
    default:
      writeln("Unsupported --as params[" ~ serverType ~ "],only support[maven|asset|blob]");
      return;
    }
    logInfo("Micdn " ~ serverType ~ " was started on http://" ~ options.listenAddr ~ options.contextPath);
    runApplication(&args);
  }

}
