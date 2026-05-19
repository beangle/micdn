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

module test.micdn.web.file_test;

import micdn.web.file;
import std.exception : assertThrown;

@("web file range encode")
unittest {
  auto s = encodeAttachmentName("早上 好.txt");
  auto expected = `attachment; filename="%E6%97%A9%E4%B8%8A%20%E5%A5%BD.txt";`
                   ~` filename*=utf-8''%E6%97%A9%E4%B8%8A%20%E5%A5%BD.txt`;
  assert(s == expected);
  auto r1 = parseRange("0-1", 2);
  assert(r1 == [0, 1]);

  auto r2 = parseRange("9500-", 10_000);
  auto r3 = parseRange("-500", 10_000);
  assert(r2 == r3);

  auto r4 = parseRange("9500-100002", 10_000);
  assert(r2 == r4);

  auto r5 = parseRange("10000-100002", 10_000);
  assert(r5 == [9999, 9999]);

  assertThrown(parseRange("0-", 0));
  assertThrown(parseRange("-1", 0));
}
