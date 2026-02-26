module micdn.main;
/// 应用入口，根据命令行参数选择并启动 maven/asset/blob 三种服务。
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

// 跑 dub test 时由测试运行器提供 main，此处不编译
version (unittest) {
} else {
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
    auto hasServer = readOption!string("as", &serverType,
        "Please specify --as params[maven|asset|blob]");
    auto servers = ["maven", "asset", "blob"];

    if (!hasServer || !(servers.canFind(serverType))) {
      writeln("Please specify --as params[maven|asset|blob]");
      writeln("Run '" ~ args[0] ~ " --help' for detailed help.");
      return;
    } else {
      auto options = getServerOptions(serverType);
      auto config = readConfig(getcwd(), serverType ~ ".xml");

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
        assetStart(options, config);
        break;
      case "blob":
        blobStart(options, config);
        break;
      default:
        writeln("Unsupported --as params[" ~ serverType ~ "],only support[maven|asset|blob]");
        writeln("Run '" ~ args[0] ~ " --help' for detailed help.");
        return;
      }
      logInfo(
          "Micdn " ~ serverType ~ " was started on http://"
          ~ options.listenAddr ~ options.contextPath);
      runApplication(&args);
    }
  }
}

void showHelpInfo(string programName) {
  immutable help = "Usage: " ~ programName ~ " [OPTIONS]\n\n"
    ~ "Required Options:\n"
    ~ "  --as TYPE          Service type (maven|asset|blob)\n\n"
    ~ "Optional Options:\n"
    ~ "  --server FILE      Server startup file path, default: listen on localhost:8080/[maven|asset|blob]\n"
    ~ "  --config FILE      Service configuration file path\n"
    ~ "  --remote URL       Remote update URL for configuration file\n\n"
    ~ "Help Options:\n"
    ~ "  --help             Show this help message and exit\n"
    ~ "  --version          Show version information and exit\n\n"
    ~ "Examples:\n"
    ~ "  " ~ programName ~ " --as maven --config maven.xml\n"
    ~ "  " ~ programName ~ " --as asset --server server.xml --config asset.xml\n"
    ~ "  " ~ programName ~ " --as blob --server server.xml --config blob.xml --remote http://example.com/config";
  writeln(help);
}

string getVersion() {
  return "0.2.0";
}
