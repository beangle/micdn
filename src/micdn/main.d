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
  if (args.canFind("--version")) {
    writeln("Micdn " ~ getVersion());
    return;
  }
  if (args.canFind("--help")) {
    showHelpInfo(args[0]);
    return;
  }

  string serverType;
  auto hasServer = readOption!string("as", &serverType, "Please specify --as params[maven|asset|blob]");
  auto servers = ["maven", "asset", "blob"];

  if (!hasServer || !(servers.canFind(serverType))) {
    writeln("Please specify --as params[maven|asset|blob]");
    writeln("Run '" ~ args[0] ~ " --help' for detailed help.");
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
      writeln("Run '" ~ args[0] ~ " --help' for detailed help.");
      return;
    }
    logInfo("Micdn " ~ serverType ~ " was started on http://" ~ options.listenAddr ~ options.contextPath);
    runApplication(&args);
  }

}

void showHelpInfo(string programName) {
  writeln("Usage: " ~ programName ~ " [OPTIONS]");
  writeln();
  writeln("Required Options:");
  writeln("  --as TYPE          Service type (maven|asset|blob)");
  writeln();
  writeln("Optional Options:");
  writeln("  --server FILE      Server startup file path, default: listen on localhost:8080/[maven|asset|blob]");
  writeln("  --config FILE      Service configuration file path");
  writeln("  --remote URL       Remote update URL for configuration file");
  writeln();
  writeln("Help Options:");
  writeln("  --help             Show this help message and exit");
  writeln("  --version          Show version information and exit");
  writeln();
  writeln("Examples:");
  writeln("  " ~ programName ~ " --as maven --config maven.xml");
  writeln("  " ~ programName ~ " --as asset --server server.xml --config asset.xml");
  writeln("  " ~ programName ~ " --as blob --server server.xml --config blob.xml --remote http://example.com/config");
}

string getVersion() {
  return "0.2.0";
}
