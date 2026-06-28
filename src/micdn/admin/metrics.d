/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.admin.metrics;
/// 进程内指标：原子计数、RSS/GC 快照、TCP 统计、idle `GC.minimize`；HTML 见 `views/metrics.dt`。

import core.atomic;
import core.memory : GC;
import core.sys.posix.unistd : getpid;
import core.time : MonoTime;

import std.algorithm : all;
import std.ascii : isDigit;
import std.conv : to;
import std.datetime;
import std.file : read;
import std.format : format;
import std.path : baseName;
import std.string : split, strip, toLower, indexOf, splitLines, startsWith;

import vibe.core.core : Timer, setTimer;
import vibe.core.log;

/// 从 `/proc/self/status` 读取的进程级内存（kB）；含代码、栈、libc、D 堆等全部 resident 页。
struct ProcessMemoryKb {
  /// VmRSS：当前驻留物理内存（kB）。空闲时仍含监听、配置、线程栈等常驻成本，不等于「未释放的请求内存」。
  ulong rssKb;
  /// VmHWM：自进程启动以来 RSS 峰值（kB）。只增不减（除非进程重启），用于观察是否曾冲高。
  ulong hwmKb;
}

/// D GC 堆快照（`GC.stats`）；仅 druntime 托管堆，不含 C malloc / 代码段 / 线程栈。
///
/// 与直觉不同，`gcUsed` 不必大于 `gcFree`：高峰回收或 `GC.minimize` 后，pool 里
/// 大量页会进 `freeSize`，空闲时常出现 gcFree ≫ gcUsed，属正常。是否泄露看 RSS/HWM 趋势，
/// 勿以二者大小关系判断。
struct GcHeapStats {
  /// 仍被 D 对象引用的堆字节（`GC.stats.usedSize`）；JSON `gcUsed`。
  size_t usedBytes;
  /// GC 已映射但尚未分配给对象、也未还给 OS 的空闲堆字节（`GC.stats.freeSize`）；JSON `gcFree`。
  size_t freeBytes;
  ulong allocatedInCurrentThread;
}

/// RSS + GC 合并快照。
struct MemSnapshot {
  ProcessMemoryKb process;
  GcHeapStats gc;
}

/// `/proc` 补充（open fd、线程数；-1 表示不可用）。
struct ProcessExtras {
  long openFds = -1;
  long threads = -1;
}

/// `GC.collect` + `GC.minimize`（及 Linux 上 `malloc_trim(0)`）前后对比。
struct GcMinimizeResult {
  MemSnapshot before;
  MemSnapshot after;
  int mallocTrim; /// `malloc_trim(0)` 返回值；非 Linux 为 -1
}

ProcessMemoryKb readProcessMemoryKb() {
  auto status = cast(string) read("/proc/" ~ getpid().to!string ~ "/status");
  ProcessMemoryKb ret;
  foreach (line; status.splitLines()) {
    if (line.startsWith("VmRSS:"))
      ret.rssKb = parseStatusKb(line);
    else if (line.startsWith("VmHWM:"))
      ret.hwmKb = parseStatusKb(line);
  }
  return ret;
}

GcHeapStats readGcHeapStats() {
  auto st = GC.stats;
  return GcHeapStats(st.usedSize, st.freeSize, st.allocatedInCurrentThread);
}

MemSnapshot snapshotMem() {
  return MemSnapshot(readProcessMemoryKb(), readGcHeapStats());
}

ProcessExtras readProcessExtras() {
  ProcessExtras ret;
  version (linux) {
    try {
      ret.openFds = countOpenFds(getpid());
    } catch (Exception) {
    }
  }
  auto status = cast(string) read("/proc/" ~ getpid().to!string ~ "/status");
  foreach (line; status.splitLines()) {
    if (line.startsWith("Threads:")) {
      ret.threads = parseStatusCount(line);
      break;
    }
  }
  return ret;
}

/** 统计 `/proc/<pid>/fd` 下数字条目数（不含 `.` / `..`）。 */
long countOpenFds(int pid) {
  version (linux) {
    import std.file : dirEntries, SpanMode;

    long n;
    foreach (entry; dirEntries(format("/proc/%s/fd", pid), SpanMode.shallow)) {
      if (isProcFdEntryName(baseName(entry.name)))
        n++;
    }
    return n;
  }
  return -1;
}

bool isProcFdEntryName(string name) pure @safe {
  return name.length && name.all!isDigit;
}

GcMinimizeResult runGcMinimize() {
  GcMinimizeResult ret;
  ret.before = snapshotMem();
  GC.collect();
  GC.minimize();
  version (Linux) {
    import core.stdc.malloc : malloc_trim;

    ret.mallocTrim = malloc_trim(0);
  } else
    ret.mallocTrim = -1;
  ret.after = snapshotMem();
  return ret;
}

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
  // memory.rssKb/hwmKb ← ProcessMemoryKb；memory.gcUsed/gcFree ← GcHeapStats.usedBytes/freeBytes
  return format(
      `{"uptimeSeconds":%s,"pid":%s,"listenPort":%s,"limits":{"maxConnections":%s,"maxRequestSize":%s,"keepAliveTimeoutSec":%s},"requests":{"total":%s,"active":%s,"activeMax":%s},"tcp":{"established":%s,"establishedMax":%s},"handlerErrors":%s,"reload":{"total":%s,"failed":%s},"gcMinimize":{"total":%s},"memory":{"rssKb":%s,"hwmKb":%s,"gcUsed":%s,"gcFree":%s,"gcAllocatedInThread":%s},"process":{"openFds":%s,"threads":%s}}`,
      s.uptimeSeconds, s.pid, s.listenPort, s.limits.maxConnections, s.limits.maxRequestSize,
      s.limits.keepAliveTimeoutSec, s.requestsTotal, s.requestsActive, s.requestsActiveMax,
      s.tcpEstablished, s.tcpEstablishedMax, s.handlerErrors, s.reloadTotal,
      s.reloadFailed, s.gcMinimizeTotal, s.mem.process.rssKb, s.mem.process.hwmKb, s.mem.gc.usedBytes,
      s.mem.gc.freeBytes, s.mem.gc.allocatedInCurrentThread, s.process.openFds, s.process.threads);
}


/// 内置 idle GC 策略（不可通过 micdn.xml 修改）。
private immutable Duration gcCheckInterval = 15.minutes;
private immutable ulong gcMinRssKb = 20 * 1024;
private immutable long gcMaxActiveRequests = 200;

/** 是否应触发 idle 收缩（纯逻辑，便于单测）。 */
bool shouldIdleMinimize(long activeRequests, ulong rssKb) {
  if (activeRequests > gcMaxActiveRequests)
    return false;
  if (rssKb < gcMinRssKb)
    return false;
  return true;
}

/// 周期性检查并在负载较低时调用 `runGcMinimize()`。
final class IdleGcMinimizer {
  private Timer _timer;
  private bool _timerActive;

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
    auto active = requestsActive();
    auto rss = readProcessMemoryKb().rssKb;
    if (!shouldIdleMinimize(active, rss))
      return;

    auto before = rss;
    runGcMinimize();
    recordGcMinimize();
    auto after = readProcessMemoryKb().rssKb;
    logInfo("GC idle minimize: RSS %s kB -> %s kB (active<=%s, min %s kB)", before, after,
        gcMaxActiveRequests, gcMinRssKb);
  }
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

private ulong parseStatusKb(string line) {
  return parseStatusCount(line);
}

private long parseStatusCount(string line) {
  auto parts = line[(line.indexOf(':') + 1) .. $].strip.split(" ");
  return parts.length ? parts[0].to!long : 0;
}

private void bumpMax(ref shared long peak, long value) @trusted nothrow {
  long cur = atomicLoad!(MemoryOrder.raw)(peak);
  while (value > cur) {
    if (cas!(MemoryOrder.raw, MemoryOrder.raw)(&peak, cur, value))
      return;
    cur = atomicLoad!(MemoryOrder.raw)(peak);
  }
}
