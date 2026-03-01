/* Copyright (C) 2023 Beangle
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

module test.micdn.fs.browser_test;

import micdn.fs.browser;

import std.algorithm;
@("web filebrowser sort entries")
unittest {
  auto entries = new FileEntry[2];
  entries[0] = new FileEntry();
  entries[1] = new FileEntry();
  entries[0].name = "av";
  entries[1].name = "a";
  sort(entries);
  assert(entries[0].name == "a");
}
