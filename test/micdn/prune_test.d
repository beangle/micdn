/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

module test.micdn.prune_test;

import core.time : hours, minutes;
import std.datetime : DateTime, LocalTime, SysTime;

import micdn.prune : untilNext;

@("untilNext picks today or tomorrow depending on the clock")
unittest {
  auto early = SysTime(DateTime(2026, 1, 1, 1, 0, 0), LocalTime());
  assert(untilNext("03:30", early) == 2.hours + 30.minutes);

  auto late = SysTime(DateTime(2026, 1, 1, 4, 0, 0), LocalTime());
  assert(untilNext("03:30", late) == 23.hours + 30.minutes);
}
