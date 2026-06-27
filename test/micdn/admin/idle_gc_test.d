/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.admin.idle_gc_test;

import std.datetime;

import core.time : MonoTime;

import micdn.admin.idle_gc;

@("admin idle gc should minimize when rss high and active requests low")
unittest {
  auto t0 = MonoTime.currTime;
  assert(shouldIdleMinimize(t0, MonoTime.init, 0, 21 * 1024));
  assert(shouldIdleMinimize(t0, MonoTime.init, 200, 20 * 1024));

  assert(!shouldIdleMinimize(t0, MonoTime.init, 201, 21 * 1024));
  assert(!shouldIdleMinimize(t0, MonoTime.init, 0, 19 * 1024));
  assert(!shouldIdleMinimize(t0, t0 - 10.minutes, 0, 21 * 1024));
}
