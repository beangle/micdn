/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.www.autodeploy;
/// HTTP 服务运行期：对 `auto-deploy="true"` 的 zip www doc 监听源文件变更并自动 deploy。

import std.algorithm : canFind;
import std.file : exists;
import std.path : absolutePath, dirName, expandTilde;

import core.time;

import vibe.core.core;
import vibe.core.log;

import micdn.model;
import micdn.www;

/** 判断 inotify 事件路径是否对应待监听的 zip 文件。 */
bool matchesAutoDeployZip(string eventPath, string zipPath) {
  import std.algorithm : equal;
  import std.path : absolutePath;

  if (eventPath.length == 0 || zipPath.length == 0)
    return false;
  return equal(absolutePath(eventPath), absolutePath(zipPath));
}

/** 运行期 zip 自动 deploy；`start`/`restart` 在 HTTP 服务启动与 SIGHUP reload 后调用。 */
final class WwwAutoDeployer {
  private MicdnConfig _config;
  private string[string] _zipToDoc;
  private Timer[string] _debounce;
  private Timer _pollTimer;
  private bool _pollActive;

  version (Linux) {
    import micdn.fs.watch;

    private Watch _watch;
    private bool _watchActive;
    private enum pollInterval = 250;
  }

  private enum debounceMs = 400;

  void start(MicdnConfig config) {
    stop();
    _config = config;
    if (config.www is null)
      return;

    version (Linux) {
      import core.sys.linux.sys.inotify;

      string[] watchDirs;
      foreach (doc; config.www.docs) {
        if (!doc.autoDeploy)
          continue;
        auto zp = cast(ZipProvider) doc.provider;
        if (zp is null) {
          logWarn("Auto-deploy www %s ignored: requires zip provider", doc.name);
          continue;
        }
        auto zipPath = absolutePath(expandTilde(zp.file));
        auto dir = dirName(zipPath);
        if (!exists(dir)) {
          logWarn("Auto-deploy www %s: zip directory not found: %s", doc.name, dir);
          continue;
        }
        _zipToDoc[zipPath] = doc.name;
        if (!watchDirs.canFind(dir))
          watchDirs ~= dir;
      }

      if (_zipToDoc.length == 0)
        return;

      _watch = watchRoots(watchDirs, IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE);
      _watchActive = true;
      _pollTimer = setTimer(pollInterval.msecs, &onPoll, true);
      _pollActive = true;
      logInfo("Auto-deploy watching %s zip doc(s) in %s director(ies)", _zipToDoc.length,
          watchDirs.length);
    } else {
      foreach (doc; config.www.docs) {
        if (doc.autoDeploy) {
          logWarn("Auto-deploy is supported on Linux only (www doc %s)", doc.name);
          return;
        }
      }
    }
  }

  void restart(MicdnConfig config) {
    start(config);
  }

  void stop() {
    foreach (name, t; _debounce)
      t.stop();
    _debounce.clear();
    if (_pollActive) {
      _pollTimer.stop();
      _pollActive = false;
    }
    version (Linux) {
      if (_watchActive) {
        _watch.stop();
        _watchActive = false;
      }
    }
    _zipToDoc.clear();
    _config = null;
  }

  version (Linux) {
    private void onPoll() @trusted {
      if (!_watchActive)
        return;
      auto events = _watch.read(0.msecs);
      if (events is null)
        return;
      foreach (e; events) {
        auto abs = absolutePath(e.path);
        if (auto p = abs in _zipToDoc)
          scheduleDeploy(*p);
      }
    }
  }

  private void scheduleDeploy(string docName) {
    if (docName in _debounce)
      _debounce[docName].stop();
    auto name = docName;
    _debounce[name] = setTimer(debounceMs.msecs, {
      if (name in _debounce)
        _debounce.remove(name);
      triggerDeploy(name);
    }, false);
  }

  private void triggerDeploy(string docName) {
    auto name = docName;
    runTask(() nothrow @system {
      doDeploy(name);
    });
  }

  private void doDeploy(string docName) nothrow {
    try {
      if (_config is null || _config.www is null)
        return;
      foreach (doc; _config.www.docs) {
        if (doc.name != docName)
          continue;
        if (!doc.autoDeploy)
          return;
        if (WwwRepo.deployDoc(_config, doc, false))
          logInfo("Auto-deploy www ok: %s", docName);
        else
          logError("Auto-deploy www %s failed", docName);
        return;
      }
    } catch (Exception e) {
      logError("Auto-deploy www %s failed: %s", docName, e.msg);
    }
  }
}
