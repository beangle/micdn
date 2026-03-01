module micdn.main;
/// 应用入口，根据命令行参数选择并启动 maven/asset/blob 三种服务。

import std.algorithm : canFind;
import std.file : getcwd, exists;
import std.range : empty;
import std.stdio;

import vibe.core.args;
import vibe.core.core;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;

import micdn.asset.web;
import micdn.blob.s3;
import micdn.blob.store;
import micdn.blob.web;
import micdn.maven.web;
import micdn.model;
import micdn.web.server;

AssetService assetService;
MavenService mavenService;
BlobService blobService;
S3Service s3Service;

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
    auto options = getServerOptions();
    auto configFile = readConfig(getcwd(), "micdn.xml");

    if (!exists(configFile)) {
      logError("Config file[" ~ configFile ~ "] not exists!");
      return;
    }
    writefln("Find config: %s", configFile);

    import std.path : dirName;

    auto home = dirName(configFile);
    auto config = MicdnConfig.parseFile(home, configFile);
    writeln("contextPath: " ~ options.contextPath);
    // contextPath "/" 会导致注册 "/repo/*" 变成 "//repo/*" 无法匹配请求路径 "/repo/xxx"
    auto routerPrefix = (options.contextPath == "/") ? "" : options.contextPath;
    auto router = new URLRouter(routerPrefix);
    auto settings = new HTTPServerSettings;

    if(config.asset !is null) {
      assetService = new AssetService(config);
      router.get(config.asset.endpoint ~ "*", &assetService.service);
      writeln("add route "~ config.asset.endpoint ~ "*");
    }

    mavenService = new MavenService(config);
    router.get(config.maven.endpoint ~ "*", &serveRepo);
    writeln("add route " ~ config.maven.endpoint ~ "*");


    if(config.blob !is null) {
      MetaDao metaDao = null;
      if (!config.blob.dataSourceProps.empty) {
        metaDao = new MetaDao(config.blob.dataSourceProps, config.blob);
      }
      auto blobService = new BlobService(config, metaDao);
      auto s3Service = new S3Service(config, metaDao);
      router.get(config.blob.endpoint ~ "*", &blobService.service);
      router.get(config.blob.endpoint ~ "/s3/*", &s3Service.service);
      settings.maxRequestSize = config.blob.maxSize;
    }

    settings.bindAddresses = options.ips.dup;
    settings.port = options.port;
    settings.serverString = null;

    listenHTTP(settings, router);
    logInfo("Micdn is started on http://" ~ options.listenAddr ~ options.contextPath);
    runApplication(&args);
  }
}

void serveRepo(HTTPServerRequest req, HTTPServerResponse res) {
  logInfo("Micdn is started on http://");
  mavenService.service(req, res);
}

void showHelpInfo(string programName) {
  immutable help = "Usage: micdn [OPTIONS]\n\n" ~ "Required Options:\n" ~ "  --as TYPE          Service type (maven|asset|blob)\n\n" ~ "Optional Options:\n" ~ "  --server FILE      Server startup file path, default: listen on localhost:8080\n" ~ "  --config FILE      Service configuration file path\n" ~ "  --remote URL       Remote update URL for configuration file\n\n" ~ "Help Options:\n" ~ "  --help             Show this help message and exit\n" ~ "  --version          Show version information and exit\n\n" ~ "Examples:\n" ~ "  micdn --config maven.xml\n" ~ "  micdn --server server.xml --config asset.xml\n" ~ "  micdn --server server.xml --config blob.xml --remote http://example.com/config";
  writeln(help);
}

string getVersion() {
  return "0.2.0";
}

// void aaa(){
//  auto uri = getPath(server.options.contextPath, req);
//   if (uri == "/config.xml") {
//     res.statusCode = 200;
//     res.headers["Content-Type"] = "application/xml";
//     res.writeBody(server.config.toXml());
//   } else {
//   }
// }

// void blobStart(ServerOptions options, string configFile) {
//   auto config = Config.parse(readXml(configFile));

//   auto repository = new Repository(config.base, metaDao);
//   server = new BlobServer(options, config, repository);
//   auto router = new URLRouter(options.contextPath);
//   router.get("*", &index);
//   router.post("*", &upload);
//   router.delete_("*", &remove);

//   // S3 protocol routes with /s3 prefix
//   router.get("/s3/*", &s3Handle);
//   router.put("/s3/*", &s3Handle);
//   router.delete_("/s3/*", &s3Handle);
//   router.match(HTTPMethod.HEAD, "/s3/*", &s3Handle);

//   auto settings = new HTTPServerSettings;
//   settings.maxRequestSize = config.maxSize;
//   settings.bindAddresses = server.options.ips.dup;
//   settings.port = server.options.port;
//   settings.serverString = null;

//   listenHTTP(settings, router);
// }
