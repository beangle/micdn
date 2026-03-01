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

module micdn.fs.watch;
/// 目录/文件变动监控封装，Linux 下基于 inotify，其它平台返回空实现。

version (Linux) {
  import std.algorithm;
  import std.exception;
  import std.file;
  import std.stdio;
  import std.string;
  import core.time;
  import core.sys.posix.unistd;
  import core.sys.posix.poll;
  import core.sys.linux.sys.inotify;
  import micdn.fs.inotify;

  public struct Watch {
    Event[] read(Duration timeout) {
      return readImpl(cast(int) timeout.total!"msecs");
    }

    Event[] read() {
      return readImpl(-1);
    }

    public @property int descriptor() {
      return queuefd;
    }

    private void addDir(string root) {
      enforce(exists(root));
      add(root, this.mask | IN_CREATE | IN_DELETE_SELF);
      foreach (d; dirEntries(root, SpanMode.breadth)) {
        if (d.isDir && !d.isSymlink)
          add(d.name, this.mask | IN_CREATE | IN_DELETE_SELF);
      }
    }

    private int add(string path, uint mask) {
      import std.conv;

      auto zpath = toStringz(path);
      auto wd = inotify_add_watch(this.queuefd, zpath, mask);
      if (wd > 0) {
        paths[wd] = path;
      }
      return wd;
    }

    private void remove(int wd) {
      paths.remove(wd);
      enforce(inotify_rm_watch(this.queuefd, wd) == 0, "failed to remove inotify watch");
    }

    private const(char)[] name(ref inotify_event e) {
      auto ptr = cast(const(char)*)(&e.name);
      return fromStringz(ptr);
    }

    private Event[] readImpl(int timeout) {
      pollfd pfd;
      pfd.fd = queuefd;
      pfd.events = POLLIN;

      if (poll(&pfd, 1, timeout) <= 0)
        return null;
      long len = .read(queuefd, buffer.ptr, buffer.length); // why .
      enforce(len > 0, "failed to read inotify event"); // test why len >0 when no event happen.
      ubyte* head = buffer.ptr;
      events.length = 0;
      events.assumeSafeAppend();
      while (len > 0) {
        auto eptr = cast(inotify_event*) head;
        auto size = (*eptr).sizeof + eptr.len;
        head += size;
        len -= size;
        string path = paths[eptr.wd];
        path ~= "/" ~ name(*eptr);
        auto e = Event(eptr.wd, eptr.mask, eptr.cookie, path);
        if (e.mask & IN_ISDIR) {
          if (e.mask & IN_CREATE) {
            add(path, this.mask | IN_CREATE | IN_DELETE_SELF);
          } else if (e.mask & IN_DELETE_SELF) {
            remove(e.wd);
          }
        }
        if (mask & e.mask) {
          events ~= e;
        }
      }
      return events;
    }

    private int queuefd = -1; // inotify event queue file discriptor
    private string[] roots;
    private int mask;
    private string[uint] paths;
    private ubyte[] buffer;
    private Event[] events;

    this(int queuefd, string[] roots, int mask) {
      enforce(queuefd >= 0, "failed to init inotify");
      this.queuefd = queuefd;
      this.mask = mask;
      //see http://man7.org/linux/man-pages/man7/inotify.7.html
      buffer = new ubyte[1024 * (inotify_event.sizeof + 256)];
      this.roots = roots;
      foreach (string root; roots) {
        this.addDir(root);
      }
    }

    ~this() {
      stop();
    }

    void stop() {
      if (queuefd >= 0) {
        close(queuefd);
        queuefd = -1;
      }
    }
  }

  public auto watch(string base, int mask) {
    return Watch(inotify_init1(IN_NONBLOCK), [base], mask);
  }
} else {
  import std.exception;
  import micdn.fs.inotify;
  import core.time : Duration;

  public struct Watch {
    Event[] read(Duration timeout) {
      return null;
    }

    Event[] read() {
      return null;
    }

    public @property int descriptor() {
      return -1;
    }

    void stop() {
    }
  }

  public auto watch(string base, int mask) {
    throw new Exception("watch not supported on this platform");
  }
}
