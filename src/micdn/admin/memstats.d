/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.admin.memstats;
/// 进程 RSS / D GC 堆读取与 `GC.minimize`（供 idle 收缩与 metrics 快照）。

import core.memory : GC;
import core.sys.posix.unistd : getpid;

import std.conv : to;
import std.file : read;
import std.format : format;
import std.string : strip, split, indexOf, splitLines, startsWith;
import std.path : baseName;
import std.ascii : isDigit;
import std.algorithm : all;

/// 从 `/proc/self/status` 读取的进程内存（kB）。
struct ProcessMemoryKb {
  ulong rssKb;
  ulong hwmKb;
}

/// D GC 堆快照（`GC.stats`）。
struct GcHeapStats {
  size_t usedBytes;
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

private ulong parseStatusKb(string line) {
  return parseStatusCount(line);
}

private long parseStatusCount(string line) {
  auto parts = line[(line.indexOf(':') + 1) .. $].strip.split(" ");
  return parts.length ? parts[0].to!long : 0;
}
