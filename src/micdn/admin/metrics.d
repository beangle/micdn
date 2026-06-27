/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.admin.metrics;
/// 进程内原子计数与内存/TCP 快照，供 `/admin/metrics.json` 与 `/admin/metrics` 只读输出。

import core.atomic;
import core.sys.posix.unistd : getpid;
import core.time : MonoTime;

import std.conv : to;
import std.file : read;
import std.format : format;
import std.string : split, toLower, indexOf, splitLines;

import micdn.admin.memstats : MemSnapshot, ProcessExtras, readProcessExtras, snapshotMem;

shared long g_requestsActive;
shared long g_requestsActiveMax;
shared long g_requestsTotal;
shared long g_tcpEstablishedMax;
shared long g_handlerErrors;
shared long g_reloadTotal;
shared long g_reloadFailed;
shared long g_gcMinimizeTotal;
shared long g_startMonoTicks;
shared ulong g_maxRequestSize;
shared long g_keepAliveTimeoutSec;
shared ushort g_listenPort;

void markProcessStarted() @safe nothrow {
  atomicStore!(MemoryOrder.raw)(g_startMonoTicks, MonoTime.currTime.ticks);
}

void setListenPort(ushort port) @safe nothrow {
  atomicStore!(MemoryOrder.raw)(g_listenPort, port);
}

void setLimits(ulong maxRequestSize, long keepAliveTimeoutSec) @safe nothrow {
  atomicStore!(MemoryOrder.raw)(g_maxRequestSize, maxRequestSize);
  atomicStore!(MemoryOrder.raw)(g_keepAliveTimeoutSec, keepAliveTimeoutSec);
}

void requestStarted() @safe nothrow {
  atomicFetchAdd!(MemoryOrder.raw)(g_requestsTotal, 1);
  auto active = atomicFetchAdd!(MemoryOrder.raw)(g_requestsActive, 1) + 1;
  bumpMax(g_requestsActiveMax, active);
}

void requestFinished() @safe nothrow {
  atomicFetchSub!(MemoryOrder.raw)(g_requestsActive, 1);
}

void recordHandlerError() @safe nothrow {
  atomicFetchAdd!(MemoryOrder.raw)(g_handlerErrors, 1);
}

void recordReload(bool ok) @safe nothrow {
  atomicFetchAdd!(MemoryOrder.raw)(g_reloadTotal, 1);
  if (!ok)
    atomicFetchAdd!(MemoryOrder.raw)(g_reloadFailed, 1);
}

void recordGcMinimize() @safe nothrow {
  atomicFetchAdd!(MemoryOrder.raw)(g_gcMinimizeTotal, 1);
}

long requestsActive() @safe nothrow {
  return atomicLoad!(MemoryOrder.raw)(g_requestsActive);
}

long requestsTotal() @safe nothrow {
  return atomicLoad!(MemoryOrder.raw)(g_requestsTotal);
}

struct MetricsLimits {
  long maxConnections = -1;
  ulong maxRequestSize;
  long keepAliveTimeoutSec;
}

struct MetricsSnapshot {
  long uptimeSeconds;
  int pid;
  ushort listenPort;
  MetricsLimits limits;
  long requestsTotal;
  long requestsActive;
  long requestsActiveMax;
  long tcpEstablished;
  long tcpEstablishedMax;
  long handlerErrors;
  long reloadTotal;
  long reloadFailed;
  long gcMinimizeTotal;
  MemSnapshot mem;
  ProcessExtras process;
}

MetricsSnapshot snapshotMetrics() {
  auto port = atomicLoad!(MemoryOrder.raw)(g_listenPort);
  long tcp = port ? countEstablishedConnections(port) : 0;
  bumpMax(g_tcpEstablishedMax, tcp);
  auto startTicks = atomicLoad!(MemoryOrder.raw)(g_startMonoTicks);
  long uptimeSec = 0;
  if (startTicks > 0)
    uptimeSec = (MonoTime.currTime.ticks - startTicks) / MonoTime.ticksPerSecond;
  return MetricsSnapshot(uptimeSec, getpid(), port,
      MetricsLimits(-1, atomicLoad!(MemoryOrder.raw)(g_maxRequestSize),
          atomicLoad!(MemoryOrder.raw)(g_keepAliveTimeoutSec)), requestsTotal(), requestsActive(),
      atomicLoad!(MemoryOrder.raw)(g_requestsActiveMax), tcp,
      atomicLoad!(MemoryOrder.raw)(g_tcpEstablishedMax),
      atomicLoad!(MemoryOrder.raw)(g_handlerErrors), atomicLoad!(MemoryOrder.raw)(g_reloadTotal),
      atomicLoad!(MemoryOrder.raw)(g_reloadFailed), atomicLoad!(MemoryOrder.raw)(g_gcMinimizeTotal),
      snapshotMem(), readProcessExtras());
}

string metricsJson(MetricsSnapshot s) {
  return format(
      `{"uptimeSeconds":%s,"pid":%s,"listenPort":%s,"limits":{"maxConnections":%s,"maxRequestSize":%s,"keepAliveTimeoutSec":%s},"requests":{"total":%s,"active":%s,"activeMax":%s},"tcp":{"established":%s,"establishedMax":%s},"handlerErrors":%s,"reload":{"total":%s,"failed":%s},"gcMinimize":{"total":%s},"memory":{"rssKb":%s,"hwmKb":%s,"gcUsed":%s,"gcFree":%s,"gcAllocatedInThread":%s},"process":{"openFds":%s,"threads":%s}}`,
      s.uptimeSeconds, s.pid, s.listenPort, s.limits.maxConnections, s.limits.maxRequestSize,
      s.limits.keepAliveTimeoutSec, s.requestsTotal, s.requestsActive, s.requestsActiveMax,
      s.tcpEstablished, s.tcpEstablishedMax, s.handlerErrors, s.reloadTotal,
      s.reloadFailed, s.gcMinimizeTotal, s.mem.process.rssKb, s.mem.process.hwmKb, s.mem.gc.usedBytes,
      s.mem.gc.freeBytes, s.mem.gc.allocatedInCurrentThread, s.process.openFds, s.process.threads);
}

string metricsPageHtml(string appVersion) {
  return `<!DOCTYPE html>
<html lang="zh">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Micdn Metrics</title>
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "SF Pro Text", "Segoe UI", system-ui, sans-serif;
      background: #f5f5f0;
      color: #2c2c2c;
      min-height: 100vh;
      padding: 1.5rem 1rem 2.5rem;
    }
    .wrap { max-width: 960px; margin: 0 auto; }
    header {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 1rem;
      margin-bottom: 1.25rem;
    }
    h1 { margin: 0; font-size: 1.35rem; font-weight: 600; }
    .meta { font-size: 0.8rem; color: #888; }
    .meta span { margin-left: 0.75rem; }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 0.85rem;
    }
    .card {
      background: #fff;
      border-radius: 10px;
      box-shadow: 0 1px 3px rgba(0,0,0,0.08);
      padding: 1rem 1.1rem;
    }
    .card.wide { grid-column: 1 / -1; }
    .card h2 {
      margin: 0 0 0.75rem;
      font-size: 0.72rem;
      font-weight: 600;
      letter-spacing: 0.06em;
      text-transform: uppercase;
      color: #888;
    }
    .stat {
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      padding: 0.28rem 0;
      font-size: 0.9rem;
    }
    .stat .label { color: #666; }
    .stat .value {
      font-family: "SF Mono", "Cascadia Code", "Consolas", monospace;
      font-weight: 500;
    }
    .stat .value.warn { color: #c64600; }
    .ops-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
      gap: 0.55rem;
    }
    .ops-grid .stat {
      width: 100%;
      margin: 0;
      padding: 0.45rem 0.65rem;
      background: #fafaf8;
      border: 1px solid #ececea;
      border-radius: 6px;
      gap: 0.75rem;
    }
    .ops-grid .stat .label { flex: 1 1 auto; min-width: 0; }
    .ops-grid .stat .value {
      flex: 0 0 auto;
      text-align: right;
      white-space: nowrap;
    }
    .bar-wrap { margin-top: 0.35rem; }
    .bar {
      height: 6px;
      background: #eee;
      border-radius: 3px;
      overflow: hidden;
    }
    .bar > i {
      display: block;
      height: 100%;
      background: linear-gradient(90deg, #3584e4, #1c71d8);
      border-radius: 3px;
      width: 0%;
      transition: width 0.3s ease;
    }
    .footer {
      margin-top: 1.5rem;
      text-align: center;
      font-size: 0.75rem;
      color: #999;
    }
    .footer a { color: #999; text-decoration: none; }
    .footer a:hover { color: #666; }
    .err {
      display: none;
      margin-bottom: 1rem;
      padding: 0.75rem 1rem;
      background: #fdecea;
      color: #c01c28;
      border-radius: 8px;
      font-size: 0.85rem;
    }
    @media (prefers-color-scheme: dark) {
      body { background: #1a1a1a; color: #e4e4e4; }
      .meta, .card h2 { color: #909090; }
      .card { background: #2d2d2d; box-shadow: 0 1px 3px rgba(0,0,0,0.35); }
      .stat .label { color: #b0b0b0; }
      .stat .value.warn { color: #ff7800; }
      .ops-grid .stat {
        background: #252525;
        border-color: #404040;
      }
      .bar { background: #404040; }
      .err { background: #3d1f1f; color: #ff6b6b; }
      .footer, .footer a { color: #6b6b6b; }
      .footer a:hover { color: #909090; }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <header>
      <h1>Micdn Metrics</h1>
      <div class="meta">
        <span id="version">` ~ appVersion ~ `</span>
        <span id="updated">—</span>
      </div>
    </header>
    <div class="err" id="err"></div>
    <div class="grid">
      <section class="card">
        <h2>Load</h2>
        <div class="stat"><span class="label">Total requests</span><span class="value" id="reqTotal">—</span></div>
        <div class="stat"><span class="label">Active requests</span><span class="value" id="reqActive">—</span></div>
        <div class="stat"><span class="label">Peak active</span><span class="value" id="reqActiveMax">—</span></div>
        <div class="bar-wrap"><div class="bar"><i id="reqBar"></i></div></div>
        <div class="stat"><span class="label">TCP established</span><span class="value" id="tcpEst">—</span></div>
        <div class="stat"><span class="label">Peak TCP</span><span class="value" id="tcpEstMax">—</span></div>
        <div class="stat"><span class="label">Req/s (avg)</span><span class="value" id="reqRate">—</span></div>
      </section>
      <section class="card">
        <h2>Memory</h2>
        <div class="stat"><span class="label">RSS</span><span class="value" id="rss">—</span></div>
        <div class="stat"><span class="label">HWM</span><span class="value" id="hwm">—</span></div>
        <div class="stat"><span class="label">GC used</span><span class="value" id="gcUsed">—</span></div>
        <div class="stat"><span class="label">GC free</span><span class="value" id="gcFree">—</span></div>
      </section>
      <section class="card">
        <h2>Process</h2>
        <div class="stat"><span class="label">PID</span><span class="value" id="pid">—</span></div>
        <div class="stat"><span class="label">Uptime</span><span class="value" id="uptime">—</span></div>
        <div class="stat"><span class="label">Listen port</span><span class="value" id="port">—</span></div>
        <div class="stat"><span class="label">Open FDs</span><span class="value" id="fds">—</span></div>
        <div class="stat"><span class="label">Threads</span><span class="value" id="threads">—</span></div>
      </section>
      <section class="card wide">
        <h2>Limits &amp; ops</h2>
        <div class="ops-grid">
          <div class="stat"><span class="label">Max connections</span><span class="value" id="maxConn">—</span></div>
          <div class="stat"><span class="label">Max request size</span><span class="value" id="maxReq">—</span></div>
          <div class="stat"><span class="label">Keep-alive timeout</span><span class="value" id="keepAlive">—</span></div>
          <div class="stat"><span class="label">Reloads</span><span class="value" id="reload">—</span></div>
          <div class="stat"><span class="label">GC minimize</span><span class="value" id="gcMin">—</span></div>
          <div class="stat"><span class="label">Handler errors</span><span class="value" id="handlerErr">—</span></div>
        </div>
      </section>
    </div>
    <div class="footer">
      Auto-refresh 5s · <a href="metrics.json">JSON</a> ·
      <a href="https://github.com/beangle/micdn">Beangle Micdn</a>
    </div>
  </div>
  <script>
    function fmt(n) {
      if (n == null || n < 0) return "—";
      return Number(n).toLocaleString();
    }
    function fmtKb(kb) {
      if (kb == null || kb < 0) return "—";
      if (kb >= 1024) return (kb / 1024).toFixed(1) + " MB";
      return kb + " kB";
    }
    function fmtBytes(b) {
      if (b == null || b < 0) return "—";
      if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB";
      if (b >= 1024) return (b / 1024).toFixed(1) + " kB";
      return b + " B";
    }
    function fmtDuration(sec) {
      if (!sec || sec < 0) return "—";
      var d = Math.floor(sec / 86400);
      var h = Math.floor((sec % 86400) / 3600);
      var m = Math.floor((sec % 3600) / 60);
      var s = sec % 60;
      if (d) return d + "d " + h + "h " + m + "m";
      if (h) return h + "h " + m + "m " + s + "s";
      if (m) return m + "m " + s + "s";
      return s + "s";
    }
    function set(id, text) {
      document.getElementById(id).textContent = text;
    }
    function apply(m) {
      var req = m.requests || {};
      var tcp = m.tcp || {};
      var mem = m.memory || {};
      var lim = m.limits || {};
      var proc = m.process || {};
      var rel = m.reload || {};
      var gc = m.gcMinimize || {};
      set("reqActive", fmt(req.active));
      set("reqActiveMax", fmt(req.activeMax));
      set("reqTotal", fmt(req.total));
      set("tcpEst", fmt(tcp.established));
      set("tcpEstMax", fmt(tcp.establishedMax));
      var rate = m.uptimeSeconds > 0 ? (req.total / m.uptimeSeconds).toFixed(2) : "0";
      set("reqRate", rate);
      var peak = req.activeMax || 1;
      document.getElementById("reqBar").style.width =
        Math.min(100, (req.active / peak) * 100).toFixed(1) + "%";
      set("rss", fmtKb(mem.rssKb));
      set("hwm", fmtKb(mem.hwmKb));
      set("gcUsed", fmtBytes(mem.gcUsed));
      set("gcFree", fmtBytes(mem.gcFree));
      set("pid", fmt(m.pid));
      set("uptime", fmtDuration(m.uptimeSeconds));
      set("port", m.listenPort || "—");
      set("fds", fmt(proc.openFds));
      set("threads", fmt(proc.threads));
      set("maxConn", lim.maxConnections < 0 ? "unlimited" : fmt(lim.maxConnections));
      set("maxReq", fmtBytes(lim.maxRequestSize));
      set("keepAlive", lim.keepAliveTimeoutSec != null ? lim.keepAliveTimeoutSec + "s" : "—");
      set("reload", fmt(rel.total) + (rel.failed ? " (" + rel.failed + " failed)" : ""));
      set("gcMin", fmt(gc.total));
      set("handlerErr", fmt(m.handlerErrors));
      set("updated", new Date().toLocaleTimeString());
      document.getElementById("err").style.display = "none";
    }
    async function refresh() {
      try {
        var r = await fetch("metrics.json", { cache: "no-store" });
        if (!r.ok) throw new Error(r.status + " " + r.statusText);
        apply(await r.json());
      } catch (e) {
        var el = document.getElementById("err");
        el.textContent = "Failed to load metrics.json: " + e.message;
        el.style.display = "block";
      }
    }
    refresh();
    setInterval(refresh, 5000);
  </script>
</body>
</html>`;
}

/** 统计本进程在 `port` 上的 TCP ESTABLISHED 连接数（scrape 时读 `/proc`）。 */
private long countEstablishedConnections(ushort port) {
  long n;
  n += countEstablishedInProcFile("/proc/net/tcp", port);
  n += countEstablishedInProcFile("/proc/net/tcp6", port);
  return n;
}

private long countEstablishedInProcFile(string path, ushort port) {
  long n;
  auto hexPort = format("%X", port);
  string content;
  try
    content = cast(string) read(path);
  catch (Exception)
    return 0;
  foreach (line; content.splitLines()) {
    auto parts = line.split();
    if (parts.length < 4)
      continue;
    if (parts[3] != "01")
      continue;
    auto colon = parts[1].indexOf(':');
    if (colon < 0)
      continue;
    if (parts[1][colon + 1 .. $].toLower == hexPort)
      n++;
  }
  return n;
}

private void bumpMax(ref shared long peak, long value) @trusted nothrow {
  long cur = atomicLoad!(MemoryOrder.raw)(peak);
  while (value > cur) {
    if (cas!(MemoryOrder.raw, MemoryOrder.raw)(&peak, cur, value))
      return;
    cur = atomicLoad!(MemoryOrder.raw)(peak);
  }
}
