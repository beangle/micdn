module micdn.main;
import std.stdio;
import micdn.web.server;
import vibe.core.args;
import vibe.core.core;
import vibe.core.log;
import micdn.maven.server : mavenStart;
import micdn.asset.server : assetStart;
import micdn.blob.server : blobStart;

void main(string[] args) {
  if (args.length < 5) {
    writeln("Usage: " ~ args[0] ~ " --as maven --server path/to/server.xml --config path/to/config.xml");
    writeln("Usage: " ~ args[0] ~ " --as asset --server path/to/server.xml --config path/to/config.xml");
    writeln("Usage: " ~ args[0] ~ " --as blob --server path/to/server.xml --config path/to/config.xml");
    return;
  }

  auto serverOptions = getServerOptions();

  string serverType;
  auto success = readOption!string("as", &serverType, "Please specify --as params[maven|asset|blob]");
  if (!success) {
    writeln("Please specify --as params[maven|asset|blob]");
    return;
  } else {
    switch (serverType) {
    case "maven":
      auto home = getHome("~/.m2/repository");
      mavenStart(home, serverOptions, getConfigFile(home, "/maven.xml", true));
      break;
    case "asset":
      auto home = getHome();
      assetStart(home, serverOptions, getConfigFile(home, "/asset.xml", true));
      break;
    case "blob":
      auto home = getHome();
      blobStart(home, serverOptions, getConfigFile(home, "/blob.xml", true));
      break;
    default:
      writeln("Unsupported --as params[" ~ serverType ~ "],only support[maven|asset|blob]");
      return;
    }
    logInfo("Micdn " ~ serverType ~ " was started on http://" ~ serverOptions.listenAddr ~ serverOptions.contextPath);
    runApplication(&args);
  }

}
