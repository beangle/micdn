/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.admin.metrics;
/// 进程内指标：请求/连接原子计数、TCP 统计与 admin JSON 暴露；
/// 内存采样与周期回收见 `micdn.runtime`，HTML 见 `views/metrics.dt`。

import core.atomic;
import core.sys.posix.unistd : getpid;
import core.time : MonoTime;

import std.file : read;
import std.format : format;
import std.string : split, strip, toLower, indexOf, splitLines;

import micdn.runtime : MemSnapshot, ProcessExtras, snapshotMem, readProcessExtras;

shared long g_requestsActive;
shared long g_requestsActiveMax;
shared long g_requestsTotal;
shared long g_tcpEstablishedMax;
shared long g_handlerErrors;
shared long g_reloadTotal;
shared long g_reloadFailed;
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
      atomicLoad!(MemoryOrder.raw)(g_reloadFailed), snapshotMem(), readProcessExtras());
}

string metricsJson(MetricsSnapshot s) {
  // memory.rssKb/hwmKb ← ProcessMemoryKb；memory.gcUsed/gcFree/gcMaxPoolSize ← GcHeapStats
  return format(
      `{"uptimeSeconds":%s,"pid":%s,"listenPort":%s,"limits":{"maxConnections":%s,"maxRequestSize":%s,"keepAliveTimeoutSec":%s},"requests":{"total":%s,"active":%s,"activeMax":%s},"tcp":{"established":%s,"establishedMax":%s},"handlerErrors":%s,"reload":{"total":%s,"failed":%s},"memory":{"rssKb":%s,"hwmKb":%s,"gcUsed":%s,"gcFree":%s,"gcMaxPoolSize":%s,"gcCollections":%s,"gcAllocatedInThread":%s},"process":{"openFds":%s,"threads":%s}}`,
      s.uptimeSeconds, s.pid, s.listenPort, s.limits.maxConnections, s.limits.maxRequestSize,
      s.limits.keepAliveTimeoutSec, s.requestsTotal, s.requestsActive, s.requestsActiveMax,
      s.tcpEstablished, s.tcpEstablishedMax, s.handlerErrors, s.reloadTotal,
      s.reloadFailed, s.mem.process.rssKb, s.mem.process.hwmKb, s.mem.gc.usedBytes,
      s.mem.gc.freeBytes, s.mem.gc.maxPoolSizeBytes, s.mem.gc.collections, s.mem.gc.allocatedInCurrentThread,
      s.process.openFds, s.process.threads);
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
