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

module test.micdn.fs.watch_test;

import micdn.fs.watch;
import micdn.fs.inotify;

version (Linux) {
  import core.sys.linux.sys.inotify;
  import core.thread;
  import core.time;
  import std.process;

  @("fs watch inotify linux")
  unittest {
    executeShell("rm -rf temp");
    executeShell("mkdir temp");
    auto monitor = watch("temp", IN_CREATE | IN_DELETE);
    executeShell("touch temp/killme");
    auto events = monitor.read();
    assert(events[0].mask == IN_CREATE);
    assert(events[0].path == "temp/killme");

    executeShell("rm -rf temp/killme");
    events = monitor.read();
    assert(events[0].mask == IN_DELETE);

    // watched directory and new sub-directory is not watched.
    executeShell("mkdir temp/dir");
    executeShell("touch temp/dir/victim");
    events = monitor.read();
    assert(events.length == 1);
    assert(events[0].mask == (IN_ISDIR | IN_CREATE));
    assert(events[0].path == "temp/dir");

    //monitor tree
    executeShell("rm -rf temp");
    executeShell("mkdir -p temp/dir1");
    executeShell("mkdir -p temp/dir2");
    monitor = watch("temp", IN_CREATE | IN_DELETE);
    executeShell("touch temp/dir1/a.temp");
    executeShell("touch temp/dir2/b.temp");
    executeShell("rm -rf temp/dir2");
    auto evs = monitor.read();
    assert(evs.length == 4);
    // a & b files created
    assert(evs[0].mask == IN_CREATE && evs[0].path == "temp/dir1/a.temp");
    assert(evs[1].mask == IN_CREATE && evs[1].path == "temp/dir2/b.temp");
    // b deleted as part of sub-tree
    assert(evs[2].mask == IN_DELETE && evs[2].path == "temp/dir2/b.temp");
    assert(evs[3].mask == (IN_DELETE | IN_ISDIR) && evs[3].path == "temp/dir2");
    evs = monitor.read(10.msecs);
    assert(evs.length == 0);

    auto t = new Thread(() {
      Thread.sleep(1000.msecs);
      executeShell("touch temp/dir1/c.temp");
    }).start();
    evs = monitor.read(10.msecs);
    t.join();
    assert(evs.length == 0);
    evs = monitor.read(10.msecs);
    assert(evs.length == 1);

    executeShell("rm -rf temp");
  }
} else {
  @("fs watch unsupported platform")
  unittest {
    // no-op on non-Linux platforms
  }
}
