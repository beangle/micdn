/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.admin.memstats_test;

import std.string;

import core.sys.posix.unistd : getpid;

import micdn.admin.memstats;

@("admin memstats reads own process rss")
unittest {
  auto pm = readProcessMemoryKb();
  assert(pm.rssKb > 0);
  assert(pm.hwmKb >= pm.rssKb);
}

@("admin memstats json snapshot shape")
unittest {
  auto s = snapshotMem();
  assert(s.process.rssKb > 0);
  assert(s.gc.usedBytes >= 0);
}

@("admin memstats count open fds ignores dot entries")
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

@("admin memstats gc minimize after alloc")
unittest {
  ubyte[] hold = new ubyte[1024 * 1024];
  hold[0] = 1;
  auto before = snapshotMem();
  hold = null;
  auto r = runGcMinimize();
  assert(r.after.gc.usedBytes <= before.gc.usedBytes);
  assert(r.after.process.rssKb > 0);
}
