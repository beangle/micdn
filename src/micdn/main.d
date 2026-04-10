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
import std.array : join;
import std.conv : to;
import std.format : format;
import std.exception;
import std.typecons : tuple, Tuple;
import std.file : getcwd, exists;
import std.range : empty;
import std.stdio;
import std.string : startsWith, strip, lastIndexOf;
import std.path : dirName, expandTilde;

import vibe.core.args;
import vibe.core.core;
import vibe.core.log;

import vibe.http.common : HTTPMethod;
import vibe.http.router;
import vibe.http.server;

import micdn.routes;

import micdn.admin.web;
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
import micdn.config;
import micdn.logging;

/// 可热加载的请求分发器：持有一个可替换的 URLRouter，支持通过 SIGHUP 完整热加载配置。
class ReloadableDispatcher : HTTPServerRequestHandler {
  private URLRouter _currentRouter;
  private string _configFile;
  private string _routerPrefix;
  private HTTPServerSettings _settings;

  this(string configFile, string routerPrefix, HTTPServerSettings settings) {
    _configFile = configFile;
    _routerPrefix = routerPrefix;
    _settings = settings;
  }

  void setRouter(URLRouter router) {
    _currentRouter = router;
  }

  override void handleRequest(HTTPServerRequest req, HTTPServerResponse res) {
    _currentRouter.handleRequest(req, res);
  }

  ReloadResult tryReload() {
    try {
      fetchRemoteIfNeeded(_configFile);
      auto config = parseFile(_configFile);
      auto router = buildRouter(config, _settings, () => this.tryReload());
      if (config.blob !is null)
        _settings.maxRequestSize = config.blob.maxSize;
      _currentRouter = router;
      return ReloadResult(true, null);
    } catch (Exception e) {
      logError("Reload failed: %s", e.msg);
      return ReloadResult(false, e.msg);
    }
  }
}

/// 根据 config 构建 URLRouter，注册所有服务路由。
URLRouter buildRouter(MicdnConfig config, HTTPServerSettings settings,
    ReloadResult delegate() onReload) {
  auto router = new URLRouter("");

  auto adminService = new AdminService(config, onReload);
  registerEndpoint(router, "/admin", &adminService.service);

  if (config.asset !is null) {
    auto assetService = new AssetService(config);
    registerEndpointGetHead(router, mountStatic, &assetService.service);
  }

  auto mavenService = new MavenService(config);
  registerEndpointGetHead(router, mountMaven, &mavenService.service);

  auto npmService = new NpmService(config);
  registerEndpointGetHead(router, mountNpm, &npmService.service);

  if (config.blob !is null) {
    auto blobRepo = new BlobRepo(config.blob);
    auto blobService = new BlobService(blobRepo);
    auto s3Service = new S3Service(blobRepo);
    registerEndpointAny(router, mountBlob, &blobService.service);
    registerEndpointAny(router, mountS3, &s3Service.service);
    settings.maxRequestSize = config.blob.maxSize;
  }

  if (config.www !is null) {
    logInfo("Building docs at %s", config.www.base);
    foreach (doc; config.www.docs) {
      if (doc.provider is null) {
        logWarn("Www doc provider is null: %s", doc.location);
        continue;
      }
      auto repo = WwwDocRepo.build(config, doc);
      auto svc = new WwwDocService(doc, repo);
      registerEndpointGetHead(router, doc.location, &svc.service);
    }
  }

  logRegisteredEndpoints(config);
  return router;
}

/// 打印已挂载的 HTTP 端点（与 `buildRouter` 中 `registerEndpoint` / `router.get` 一致）。
void logRegisteredEndpoints(MicdnConfig config) {
  string[] parts = ["/admin"];
  if (config.asset !is null)
    parts ~= mountStatic;
  parts ~= mountMaven;
  parts ~= mountNpm;
  if (config.blob !is null) {
    parts ~= mountBlob;
    parts ~= mountS3;
  }
  if (config.www !is null) {
    foreach (doc; config.www.docs) {
      if (doc.provider is null)
        continue;
      parts ~= format("%s", doc.location);
    }
  }
  logInfo("Registered HTTP endpoints: %s", parts.join(", "));
}

// 跑 dub test 时由测试运行器提供 main，此处不编译
version (unittest) {
} else {
  int main(string[] args) {
    if (args.canFind("--version") || args.canFind("-v")) {
      writeln("Micdn " ~ getVersion());
      return 0;
    }
    if (args.canFind("--help") || args.canFind("-h")) {
      showHelpInfo();
      return 0;
    }
    bool hasConfig = args.canFind("-f");
    if (!hasConfig) {
      showHelpInfo();
      return 1;
    }
    string configFile;
    try {
      configFile = resolveConfigFile("micdn.xml");

      if (!exists(expandTilde(configFile))) {
        logError("Config file[" ~ configFile ~ "] not exists!");
        return 1;
      }

      auto configPath = expandTilde(configFile);
      auto config = parseFile(configPath);
      applyMicdnLogging(config.logFile, config.logLevel);
      logInfo("Find config: %s", configFile);

      auto listenPair = parseListen(config.listen);
      auto host = listenPair[0];
      auto port = listenPair[1];

      auto settings = new HTTPServerSettings;
      settings.bindAddresses = [host];
      settings.port = port;
      settings.serverString = null;

      auto dispatcher = new ReloadableDispatcher(configPath, "", settings);
      dispatcher.setRouter(buildRouter(config, settings, () => dispatcher.tryReload()));

      auto listener = listenHTTP(settings, dispatcher);
      scope (exit)
        listener.stopListening();

      version (Posix) {
        startSighupReloadThread(dispatcher);
      }

      runApplication(&args);
      return 0;
    } catch (Exception e) {
      logError("%s", e.msg);
      return 1;
    }
  }
}

/// 启动 SIGHUP 监听线程，收到信号时在事件循环中触发 reload（供 systemctl reload 使用）。
version (Posix) {
  void startSighupReloadThread(ReloadableDispatcher dispatcher) {
    import core.thread;

    version (Linux) {
      import core.sys.posix.signal;

      sigset_t mask;
      sigemptyset(&mask);
      sigaddset(&mask, SIGHUP);
      sigprocmask(SIG_BLOCK, &mask, null);

      auto t = new Thread({
        int sig;
        while (sigwait(&mask, &sig) == 0 && sig == SIGHUP) {
          runTask({
            auto r = dispatcher.tryReload();
            logInfo("Config reload (SIGHUP): %s", r.ok ? "ok" : ("failed: " ~ r.error));
          });
        }
      });
      t.isDaemon = true;
      t.start();
    }
  }
}

/// 为 endpoint 及其子路径注册同一 handler：endpoint 与 endpoint/*（仅 GET，适合静态/仓库读服务）。
void registerEndpoint(T)(URLRouter router, string endpoint, T handler) {
  router.get(endpoint, handler);
  router.get(endpoint ~ "/*", handler);
}

/// 同上，并注册 HEAD（与 GET 同一 handler；目录列表/重定向等由各服务对 HEAD 单独返回 405）。
void registerEndpointGetHead(T)(URLRouter router, string endpoint, T handler) {
  router.get(endpoint, handler);
  router.get(endpoint ~ "/*", handler);
  router.match(HTTPMethod.HEAD, endpoint, handler);
  router.match(HTTPMethod.HEAD, endpoint ~ "/*", handler);
}

/// 为 endpoint 及其子路径注册同一 handler（任意 HTTP 方法），由 handler 内按 `req.method` 分发（Blob、S3 等）。
void registerEndpointAny(T)(URLRouter router, string endpoint, T handler) {
  router.any(endpoint, handler);
  router.any(endpoint ~ "/*", handler);
}

/// 解析 listen 字符串 "host:port"，返回 (host, port)。
private Tuple!(string, ushort) parseListen(string listen) {
  auto idx = listen.lastIndexOf(':');
  if (idx < 0)
    throw new Exception("Invalid listen format: " ~ listen ~ ", expected host:port");
  auto host = listen[0 .. idx];
  auto port = listen[idx + 1 .. $].to!ushort;
  return tuple(host, port);
}

void showHelpInfo() {
  immutable helpRaw = `
Usage: micdn -f FILE|DIR|URL

  -f FILE    本地配置文件路径
  -f DIR     配置目录，使用 DIR/micdn.xml
  -f URL     从 URL 下载配置到 ~/micdn.xml

Help Options:
  --help      Show this help message and exit
  --version   Show version information and exit

Examples:
  micdn -f micdn.xml
  micdn -f ./conf
  micdn -f http://example.com/micdn.xml
`;
  writeln(strip(helpRaw));
}

string getVersion() {
  return "0.2.0";
}
