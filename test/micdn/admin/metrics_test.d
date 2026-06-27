/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.admin.metrics_test;

import core.atomic;

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

@("admin metrics page html loads json")
unittest {
  auto html = metricsPageHtml("0.2.5");
  assert(html.indexOf("metrics.json") >= 0);
  assert(html.indexOf("0.2.5") >= 0);
  assert(html.indexOf("Auto-refresh") >= 0);
  assert(html.indexOf("r2xx") < 0);
}
