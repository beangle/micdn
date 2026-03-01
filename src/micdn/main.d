/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

module micdn.main;
/// 应用入口，根据命令行参数选择并启动 maven/asset/blob 三种服务。

import std.algorithm : canFind, any;
import std.exception;
import std.file : getcwd, exists;
import std.range : empty;
import std.stdio;
import std.string : startsWith, strip;
import std.path : dirName;

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
import micdn.npm.web;
import micdn.web.server;
import micdn.www;
import micdn.www.web;

// 跑 dub test 时由测试运行器提供 main，此处不编译
version (unittest) {
} else {
  int main(string[] args) {
    if (args.canFind("--version")) {
      writeln("Micdn " ~ getVersion());
      return 0;
    }
    if (args.canFind("--help")) {
      showHelpInfo(args[0]);
      return 0;
    }
    bool hasConfig = args.canFind("--config") || args.canFind("-f")
      || args.any!(a => a.startsWith("--config="));
    if (!hasConfig) {
      showHelpInfo(args[0]);
      return 1;
    }
    string configFile;
    try {
      auto options = getServerOptions();
      configFile = readConfig(getcwd(), "micdn.xml");

      if (!exists(configFile)) {
        logError("Config file[" ~ configFile ~ "] not exists!");
        return 1;
      }
      logInfo("Find config: %s", configFile);

      auto home = dirName(configFile);
      auto config = MicdnConfig.parseFile(home, configFile);
      // contextPath "/" 会导致注册 "/repo/*" 变成 "//repo/*" 无法匹配请求路径 "/repo/xxx"
      auto routerPrefix = (options.contextPath == "/") ? "" : options.contextPath;
      auto router = new URLRouter(routerPrefix);
      auto settings = new HTTPServerSettings;

      if (config.asset !is null) {
        auto assetService = new AssetService(config);
        router.get(config.asset.endpoint, &assetService.service);
        router.get(config.asset.endpoint ~ "/*", &assetService.service);
      }

      auto mavenService = new MavenService(config);
      router.get(config.maven.endpoint ~ "/*", &mavenService.service);
      router.get(config.maven.endpoint, &mavenService.service);

      if (config.npm !is null) {
        auto npmService = new NpmService(config);
        router.get(config.npm.endpoint ~ "/*", &npmService.service);
        router.get(config.npm.endpoint, &npmService.service);
      }

      if (config.blob !is null) {
        MetaDao metaDao = null;
        if (!config.blob.dataSourceProps.empty) {
          metaDao = new MetaDao(config.blob.dataSourceProps, config.blob);
        }
        auto blobService = new BlobService(config, metaDao);
        auto s3Service = new S3Service(config, metaDao);
        router.get(config.blob.endpoint ~ "/*", &blobService.service);
        router.get(config.blob.endpoint ~ "/s3/*", &s3Service.service);
        settings.maxRequestSize = config.blob.maxSize;
      }

      if (config.www !is null) {
        foreach (doc; config.www.docs) {
          if (doc.provider is null){
            logWarn("Www doc provider is null: %s", doc.location);
            continue;
          }
          auto repo = WwwDocRepo.build(config, doc);
          auto svc = new WwwDocService(doc, repo);
          router.get(doc.location, &svc.service);
          router.get(doc.location ~ "/*", &svc.service);
        }
      }

      settings.bindAddresses = options.ips.dup;
      settings.port = options.port;
      settings.serverString = null;

      auto listener = listenHTTP(settings, router);
      scope (exit)
        listener.stopListening();
      runApplication(&args);
      return 0;
    } catch (Exception e) {
      logError("%s", e.msg);
      return 1;
    }
  }
}

void showHelpInfo(string programName) {
  immutable helpRaw = `
Usage: micdn -f FILE/DIR [OPTIONS]

Optional Options:
  --server FILE      Server startup file path, default: listen on localhost:8080
  --remote, -r URL   Remote update URL for configuration file

Help Options:
  --help             Show this help message and exit
  --version          Show version information and exit

Examples:
  micdn -f maven.xml
  micdn --server server.xml -f asset.xml
  micdn --server server.xml -f blob.xml -r http://example.com/config
`;
  writeln(strip(helpRaw));
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
