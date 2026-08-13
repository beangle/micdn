/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.runtime;
/// 进程运行时管理：GC 配置（不可通过 micdn.xml 修改）、`/proc` 内存采样、周期回收。
/// 非 GC 分配（vibe/eventcore 缓冲等）经 glibc malloc 的 [heap] 由 `malloc_trim` 归还
/// （dlsym 探测，musl 自动降级）；GC 部分由 `GC.collect + minimize` 归还 mmap 页池。

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

/// 内置 GC 单块 pool 上限（`core.gc.config.config.maxPoolSize`）。经 1M / 8M / 4M 同日 A/B 压测选定：
/// 4M 比 8M 运行 RSS 各阶段低 5–8MB、四场景吞吐无回退，启动后 RSS 19.6MB（见 docs/stress_report.md「内存池对比」）。
/// druntime 在 main 之前读取，不能由 micdn.xml 修改。
enum gcMaxPoolSizeMb = 4;

/// druntime 启动前读取的 GC 选项；`heapSizeFactor:1.2` 预留少量堆余量，减少运行期页池扩容。
extern (C) __gshared string[] rt_options = ["gcopt=maxPoolSize:4M heapSizeFactor:1.2"];

/** HTTP 服务启动时调用，记录内置 GC 配置（druntime 在 main 之前已读 rt_options）。 */
void applyRuntimeProfile() @safe nothrow {
  logInfo("Runtime profile: GC maxPoolSize=%sM heapSizeFactor=1.2 (periodic reclaim active)", gcMaxPoolSizeMb);
}

version (linux) {
  /// glibc 专属的 `malloc_trim`；musl（Alpine 镜像）无此符号，用 dlsym 运行时探测，找到才调用。
  private alias MallocTrimFn = int function(size_t pad) @nogc nothrow;
  private MallocTrimFn mallocTrimFn() @nogc nothrow {
    import core.sys.linux.dlfcn : dlsym, RTLD_DEFAULT;
    return cast(MallocTrimFn) dlsym(RTLD_DEFAULT, "malloc_trim");
  }
}

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
  /// druntime GC 单块 pool 上限（`core.gc.config.config.maxPoolSize`）；JSON `gcMaxPoolSize`。
  size_t maxPoolSizeBytes;
  /// 自进程启动以来 druntime full GC 次数（`GC.profileStats.numCollections`）；JSON `gcCollections`。
  size_t collections;
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

/// `malloc_trim` 返回值的可读描述：1=已归还堆内存，0=无空闲可还，-1=libc 不支持（musl）。
string mallocTrimLabel(int code) @safe pure nothrow {
  if (code > 0)
    return "trimmed";
  if (code == 0)
    return "noop";
  return "unsupported";
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

size_t readGcMaxPoolSizeBytes() {
  import core.gc.config;

  config.initialize();
  return config.maxPoolSize;
}

GcHeapStats readGcHeapStats() {
  auto st = GC.stats;
  auto collections = GC.profileStats().numCollections;
  return GcHeapStats(st.usedSize, st.freeSize, readGcMaxPoolSizeBytes(), collections,
      st.allocatedInCurrentThread);
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

/// 一次完整回收：`GC.collect`（标记-清扫，收拢仍被引用的对象）+ `GC.minimize`（把空闲页池归还 OS）
/// + Linux glibc 下 `malloc_trim(0)`（归还 C 堆 arena 空闲内存；musl 无此符号，dlsym 探测为 null 时跳过）。
/// 调用点：启动期重活后一次（main）、`PeriodicGcReclaimer` 周期、`/admin/reclaim` 按需。
GcMinimizeResult runGcMinimize() {
  GcMinimizeResult ret;
  ret.before = snapshotMem();
  GC.collect();
  GC.minimize();
  version (linux) {
    auto trim = mallocTrimFn();
    ret.mallocTrim = trim is null ? -1 : trim(0);
  } else
    ret.mallocTrim = -1;
  ret.after = snapshotMem();
  return ret;
}

/// 周期回收间隔：固定周期执行 `GC.collect + minimize + malloc_trim`，让不再需要的内存尽快归还 OS。
/// micdn 的 GC 堆很小（压测中 gcUsed 仅数 MB），collect 的 STW 代价可忽略，无需 RSS 门控；
/// 10 分钟在「回收时效」与「STW 频率」之间折中（启动期重活后另有即时回收，见 main）。
private enum Duration reclaimInterval = 10.minutes;

/// 周期 GC 回收器：固定周期执行 `GC.collect + minimize + malloc_trim`（glibc 下经 dlsym 生效，musl 自动降级），
/// 空闲时尽早归还内存、负载后回落。不读取请求计数，负载期同样执行（堆小、STW 可忽略）。
final class PeriodicGcReclaimer {
  private Timer _timer;
  private bool _running;

  void start() {
    stop();
    _timer = setTimer(reclaimInterval, &onTimer, true);
    _running = true;
  }

  void stop() {
    if (_running) {
      _timer.stop();
      _running = false;
    }
  }

  private void onTimer() @trusted {
    auto res = runGcMinimize();
    logInfo("Periodic GC reclaim: RSS %.2f MB -> %.2f MB (gcUsed %.2f -> %.2f MB, heapTrim %s)",
        res.before.process.rssKb / 1024.0, res.after.process.rssKb / 1024.0,
        res.before.gc.usedBytes / 1024.0 / 1024.0, res.after.gc.usedBytes / 1024.0 / 1024.0,
        mallocTrimLabel(res.mallocTrim));
  }
}

private ulong parseStatusKb(string line) {
  return parseStatusCount(line);
}

private long parseStatusCount(string line) {
  auto parts = line[(line.indexOf(':') + 1) .. $].strip.split(" ");
  return parts.length ? parts[0].to!long : 0;
}
