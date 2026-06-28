/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.admin.metrics_test;

import core.atomic;
import core.sys.posix.unistd : getpid;

import std.string;

import micdn.admin.metrics;

@("admin metrics atomic request counters")
unittest {
  g_requestsActive = 0;
  g_requestsActiveMax = 0;
  g_requestsTotal = 0;
  requestStarted();
  requestStarted();
  assert(requestsActive() == 2);
  assert(requestsTotal() == 2);
  assert(atomicLoad!(MemoryOrder.raw)(g_requestsActiveMax) == 2);
  requestFinished();
  assert(requestsActive() == 1);
  assert(requestsTotal() == 2);
  requestFinished();
  assert(requestsActive() == 0);
}

@("admin metrics json snapshot shape")
unittest {
  markProcessStarted();
  setLimits(1024 * 1024, 10);
  auto json = metricsJson(snapshotMetrics());
  assert(json.indexOf(`"uptimeSeconds":`) >= 0);
  assert(json.indexOf(`"requests":{"total":`) >= 0);
  assert(json.indexOf(`"activeMax":`) >= 0);
  assert(json.indexOf(`"tcp":{"established":`) >= 0);
  assert(json.indexOf(`"responses"`) < 0);
  assert(json.indexOf(`"memory":{"rssKb":`) >= 0);
  assert(json.indexOf(`"maxRequestSize":`) >= 0);
  assert(json.indexOf(`"openFds":`) >= 0);
}

@("admin metrics tcp established reads proc when port set")
unittest {
  setListenPort(65535);
  auto s = snapshotMetrics();
  assert(s.tcpEstablished >= 0);
  assert(s.listenPort == 65535);
}

@("admin metrics page template")
unittest {
  import std.file : readText;

  auto tpl = readText("views/metrics.dt");
  assert(tpl.indexOf("metrics.json") >= 0);
  assert(tpl.indexOf("pageData.appVersion") >= 0);
  assert(tpl.indexOf("Auto-refresh") >= 0);
}

@("admin metrics reads own process rss")
unittest {
  auto pm = readProcessMemoryKb();
  assert(pm.rssKb > 0);
  assert(pm.hwmKb >= pm.rssKb);
}

@("admin metrics mem snapshot shape")
unittest {
  auto s = snapshotMem();
  assert(s.process.rssKb > 0);
  assert(s.gc.usedBytes >= 0);
}

@("admin metrics count open fds ignores dot entries")
unittest {
  assert(isProcFdEntryName("0"));
  assert(isProcFdEntryName("712"));
  assert(!isProcFdEntryName("."));
  assert(!isProcFdEntryName(".."));
  assert(!isProcFdEntryName(""));
  version (linux) {
    assert(countOpenFds(getpid()) >= 3);
  }
}

@("admin metrics gc minimize after alloc")
unittest {
  ubyte[] hold = new ubyte[1024 * 1024];
  hold[0] = 1;
  auto before = snapshotMem();
  hold = null;
  auto r = runGcMinimize();
  assert(r.after.gc.usedBytes <= before.gc.usedBytes);
  assert(r.after.process.rssKb > 0);
}

@("admin metrics idle gc should minimize when rss high and active requests low")
unittest {
  assert(shouldIdleMinimize(0, 51 * 1024));
  assert(shouldIdleMinimize(200, 50 * 1024));

  assert(!shouldIdleMinimize(201, 51 * 1024));
  assert(!shouldIdleMinimize(0, 49 * 1024));
}
