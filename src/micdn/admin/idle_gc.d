/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.admin.idle_gc;
/// 定时检查：RSS 偏高且在途请求不多时触发 `GC.minimize`（无 micdn.xml 配置）。

import core.time : MonoTime;

import std.datetime;

import vibe.core.core : Timer, setTimer;
import vibe.core.log;

import micdn.admin.memstats : readProcessMemoryKb, runGcMinimize;
import micdn.admin.metrics : recordGcMinimize, requestsActive;

/// 内置策略（不可通过 micdn.xml 修改）。
private immutable Duration gcCheckInterval = 15.minutes;
private immutable ulong gcMinRssKb = 20 * 1024;
private immutable long gcMaxActiveRequests = 200;
private immutable Duration gcCooldown = 15.minutes;

/** 是否应触发收缩（纯逻辑，便于单测）。 */
bool shouldIdleMinimize(MonoTime now, MonoTime lastMinimize, long activeRequests, ulong rssKb) {
  if (activeRequests > gcMaxActiveRequests)
    return false;
  if (rssKb < gcMinRssKb)
    return false;
  if (lastMinimize != MonoTime.init && now - lastMinimize < gcCooldown)
    return false;
  return true;
}

/// 周期性检查并在负载较低时调用 `runGcMinimize()`。
final class IdleGcMinimizer {
  private Timer _timer;
  private bool _timerActive;
  private MonoTime _lastMinimize = MonoTime.init;

  void start() {
    stopTimer();
    _timer = setTimer(gcCheckInterval, &onTimer, true);
    _timerActive = true;
  }

  void stopTimer() {
    if (_timerActive) {
      _timer.stop();
      _timerActive = false;
    }
  }

  private void onTimer() @trusted {
    auto now = MonoTime.currTime;
    auto active = requestsActive();
    auto rss = readProcessMemoryKb().rssKb;
    if (!shouldIdleMinimize(now, _lastMinimize, active, rss))
      return;

    auto before = rss;
    runGcMinimize();
    recordGcMinimize();
    _lastMinimize = now;
    auto after = readProcessMemoryKb().rssKb;
    logInfo("GC idle minimize: RSS %s kB -> %s kB (active<=%s, min %s kB)", before, after,
        gcMaxActiveRequests, gcMinRssKb);
  }
}
