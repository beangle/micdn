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
import std.path : absolutePath, dirName, expandTilde;

import vibe.core.args;
import vibe.core.core;
import vibe.core.log;

import vibe.http.common : HTTPMethod, HTTPStatusException;
import vibe.http.router;
import vibe.http.server : HTTPListener;

import micdn.routes;

import micdn.admin.web;
import micdn.admin.metrics;
import micdn.asset;
import micdn.asset.web;
import micdn.blob.s3;
import micdn.blob.store;
import micdn.blob.web;
import micdn.maven.web;
import micdn.model;
import micdn.npm.web;
import micdn.web;
import micdn.www;
import micdn.www.web;
import micdn.config;
import micdn.logging;
import micdn.resolve;
import micdn.www.autodeploy;

/// 仅启动阶段失败时使用（systemd `RestartPreventExitStatus=2`）；正常运行后进程退出/崩溃用其它码，仍由 systemd 拉起。
enum ExitStartupError = 2;

private int reportStartupError(string msg) {
  stderr.writeln("micdn: ", msg);
  return ExitStartupError;
}

/// 可热加载的请求分发器：持有一个可替换的 URLRouter，支持通过 SIGHUP 完整热加载配置。
class ReloadableDispatcher : HTTPServerRequestHandler {
  private URLRouter _currentRouter;
  private string _configFile;
  private string _routerPrefix;
  private HTTPServerSettings _settings;
  private ReloadResult delegate() _onReload;

  this(string configFile, string routerPrefix, HTTPServerSettings settings,
      ReloadResult delegate() onReload) {
    _configFile = configFile;
    _routerPrefix = routerPrefix;
    _settings = settings;
    _onReload = onReload;
  }

  void setRouter(URLRouter router) {
    _currentRouter = router;
  }

  override void handleRequest(HTTPServerRequest req, HTTPServerResponse res) {
    requestStarted();
    scope (exit)
      requestFinished();
    try {
      _currentRouter.handleRequest(req, res);
    } catch (Exception e) {
      if (typeid(e) != typeid(HTTPStatusException))
        recordHandlerError();
      throw e;
    }
  }

  ReloadResult tryReload() {
    try {
      fetchRemoteIfNeeded(_configFile);
      auto config = parseFile(_configFile);
      auto listenPair = parseListen(config.listen);
      applyLimits(_settings, config);
      auto router = buildRouter(config, _settings, _onReload);
      _currentRouter = router;
      recordReload(true);
      return ReloadResult(true, null, listenPair[1], config);
    } catch (Exception e) {
      logError("Reload failed: %s", e.msg);
      recordReload(false);
      return ReloadResult(false, e.msg, 0);
    }
  }
}

private void applyLimits(HTTPServerSettings settings, MicdnConfig config) {
  if (config.blob !is null)
    settings.maxRequestSize = config.blob.maxSize;
  setLimits(settings.maxRequestSize, settings.keepAliveTimeout.total!"seconds"());
}

/// 根据 config 构建 URLRouter，注册所有服务路由。
URLRouter buildRouter(MicdnConfig config, HTTPServerSettings settings,
    ReloadResult delegate() onReload) {
  auto router = new URLRouter("");

  auto adminService = new AdminService(config, getVersion(), onReload);
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
    auto wwwRepo = WwwRepo.build(config);
    auto wwwService = new WwwService(wwwRepo);
    registerWwwCatchAll(router, &wwwService.service);
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
    string[] docLocs;
    foreach (doc; config.www.docs)
      docLocs ~= doc.endpoint();
    parts ~= "/* (www" ~ (docLocs.length ? ": " ~ docLocs.join(", ") : "") ~ ")";
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
    if (args.canFind("deploy")) {
      try {
        return runDeploy(args);
      } catch (Exception e) {
        return reportStartupError(e.msg);
      }
    }
    if (args.canFind("resolve")) {
      try {
        return runResolve(args);
      } catch (Exception e) {
        return reportStartupError(e.msg);
      }
    }
    bool hasConfig = args.canFind("-f");
    if (!hasConfig) {
      showHelpInfo();
      return ExitStartupError;
    }
    string configFile;
    ReloadableDispatcher dispatcher;
    IdleGcMinimizer idleGc;
    WwwAutoDeployer wwwAutoDeploy;
    HTTPListener listener;

    ReloadResult reloadAndSync() {
      auto r = dispatcher.tryReload();
      if (r.ok) {
        setListenPort(r.listenPort);
        wwwAutoDeploy.restart(r.config);
      }
      return r;
    }

    try {
      configFile = resolveConfigFile("micdn.xml");

      if (!exists(expandTilde(configFile)))
        return reportStartupError("Config file[" ~ configFile ~ "] not exists!");

      auto config = parseFile(expandTilde(configFile));
      applyMicdnLogging(config.logFile, config.logLevel);
      logInfo("Find config: %s", configFile);

      auto listenPair = parseListen(config.listen);
      auto host = listenPair[0];
      auto port = listenPair[1];

      auto settings = new HTTPServerSettings;
      settings.bindAddresses = [host];
      settings.port = port;
      settings.serverString = null;

      markProcessStarted();
      idleGc = new IdleGcMinimizer();
      setListenPort(port);
      applyLimits(settings, config);
      idleGc.start();

      dispatcher = new ReloadableDispatcher(absolutePath(expandTilde(configFile)), "", settings,
          &reloadAndSync);

      dispatcher.setRouter(buildRouter(config, settings, &reloadAndSync));

      listener = listenHTTP(settings, dispatcher);
      wwwAutoDeploy.start(config);
    } catch (Exception e) {
      return reportStartupError(e.msg);
    }

    scope (exit) {
      wwwAutoDeploy.stop();
      listener.stopListening();
    }

    version (Posix) {
      startSighupReloadThread(&reloadAndSync);
    }

    runApplication(&args);
    return 0;
  }
}

/// 启动 SIGHUP 监听线程，收到信号时在事件循环中触发 reload（供 systemctl reload 使用）。
version (Posix) {
  void startSighupReloadThread(ReloadResult delegate() reload) {
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
            auto r = reload();
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

/// www 兜底路由：须在 maven/npm/static/blob 等固定路由之后注册。
void registerWwwCatchAll(T)(URLRouter router, T handler) {
  router.get("/", handler);
  router.get("/*", handler);
  router.match(HTTPMethod.HEAD, "/", handler);
  router.match(HTTPMethod.HEAD, "/*", handler);
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

/// 离线部署 www/static 资源（不启动 HTTP 服务；日志固定输出到控制台 info）。
int runDeploy(string[] args) {
  if (!args.canFind("-f"))
    throw new Exception("-f is required for deploy");

  auto target = deployTargetArg(args);
  auto name = deployNameArg(args);
  auto force = deployForceArg(args);
  auto configPath = resolveConfigFile("micdn.xml");
  auto config = parseFile(expandTilde(configPath));
  applyMicdnCliLogging();

  if (target == "www")
    return runDeployWww(config, name, force);
  if (target == "static")
    return runDeployStatic(config, name, force);
  throw new Exception("deploy target must be www or static");
}

/// 解析并安装全部服务：parseFile（XML/属性）后下载缺失 artifact、deploy www/static 并校验；不启动 HTTP。
int runResolve(string[] args) {
  if (!args.canFind("-f"))
    throw new Exception("-f is required for resolve");

  auto configPath = resolveConfigFile("micdn.xml");
  auto expanded = expandTilde(configPath);
  if (!exists(expanded))
    throw new Exception("Config file[" ~ expanded ~ "] not exists!");

  fetchRemoteIfNeeded(expanded);
  auto config = parseFile(expanded);
  applyMicdnCliLogging();
  parseListen(config.listen);

  if (!resolveMicdn(config))
    return 1;

  logInfo("resolve ok: %s", expanded);
  return 0;
}

private bool deployForceArg(string[] args) {
  foreach (i, a; args) {
    if (a != "deploy" || i + 1 >= args.length)
      continue;
    foreach (j; i + 1 .. args.length) {
      if (args[j] == "--force")
        return true;
    }
  }
  return false;
}

private string deployTargetArg(string[] args) {
  foreach (i, a; args) {
    if (a == "deploy") {
      if (i + 1 >= args.length || args[i + 1].startsWith("-"))
        throw new Exception("usage: micdn -f CONFIG deploy www|static [name]");
      return args[i + 1];
    }
  }
  throw new Exception("usage: micdn -f CONFIG deploy www|static [name]");
}

private string deployNameArg(string[] args) {
  foreach (i, a; args) {
    if (a == "deploy" && i + 2 < args.length && !args[i + 2].startsWith("-"))
      return args[i + 2];
  }
  return null;
}

private int runDeployWww(MicdnConfig config, string docName, bool force) {
  if (config.www is null)
    throw new Exception("no <www> section in config");

  WwwRepo.prepareBase(config.www.base);

  if (docName.length == 0) {
    bool ok = true;
    foreach (doc; config.www.docs) {
      if (!WwwRepo.deployDoc(config, doc, force))
        ok = false;
      else
        logInfo("deploy www ok: %s -> %s", doc.name,
            resolveRepositoryPath(config.www.base, doc.endpoint()));
    }
    return ok ? 0 : 1;
  }

  auto doc = findWwwDoc(config.www, docName);

  if (!WwwRepo.deployDoc(config, doc, force))
    throw new Exception("deploy www failed for " ~ doc.name);

  logInfo("deploy www ok: %s -> %s", doc.name, resolveRepositoryPath(config.www.base, doc.endpoint()));
  return 0;
}

private int runDeployStatic(MicdnConfig config, string bundleName, bool force) {
  if (config.asset is null)
    throw new Exception("no <static> section in config");

  AssetRepo.prepareBase(config.asset.base);

  if (bundleName.length == 0) {
    bool ok = true;
    foreach (bundle; config.asset.bundles) {
      if (!AssetRepo.deployBundle(config, bundle, force))
        ok = false;
      else
        logInfo("deploy static ok: %s -> %s", bundle.name, config.asset.base ~ "/" ~ bundle.name);
    }
    return ok ? 0 : 1;
  }

  if (bundleName !in config.asset.bundles)
    throw new Exception("no <bundle name=\"" ~ bundleName ~ "\"> in config");

  if (!AssetRepo.deployBundle(config, config.asset.bundles[bundleName], force))
    throw new Exception("deploy static failed for " ~ bundleName);

  logInfo("deploy static ok: %s -> %s", bundleName, config.asset.base ~ "/" ~ bundleName);
  return 0;
}

private const(WwwDocConfig) findWwwDoc(const WwwConfig www, string docName) {
  auto name = normalizeDocName(docName);
  foreach (d; www.docs) {
    if (d.name == name)
      return d;
  }
  throw new Exception("no <doc name=\"" ~ name ~ "\"> in config");
}

void showHelpInfo() {
  immutable helpRaw = `
Usage: micdn -f FILE|DIR|URL [command]

  -f FILE    本地配置文件路径
  -f DIR     配置目录，使用 DIR/micdn.xml
  -f URL     从 URL 下载配置到 ~/micdn.xml

Commands:
  (default)              启动 HTTP 服务
  resolve                解析配置并部署 www/static（下载 jar/npm、解压 zip/tgz，校验部署目录）；不启动 HTTP；日志输出到控制台
  deploy www [NAME]      离线部署 <www> doc（NAME 如 manual 或 a/b；省略则全部）；日志输出到控制台
  deploy static [BUNDLE] 离线部署 <static> bundle（省略则全部）
                         --force  删除已有部署目录后重新安装（忽略 manifest.json）

Help Options:
  --help      Show this help message and exit
  --version   Show version information and exit

Examples:
  micdn -f micdn.xml
  micdn -f micdn.xml resolve
  micdn -f micdn.xml deploy www manual
  micdn -f micdn.xml deploy static bootstrap
  micdn -f micdn.xml deploy www manual --force
  micdn -f micdn.xml deploy www
`;
  writeln(strip(helpRaw));
}

string getVersion() {
  return "0.2.5";
}
