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

module micdn.fs.inotify;
/// 对 Linux inotify 事件与常量的轻量封装，供 fs.watch 使用。

version (Linux) {
  import core.sys.linux.sys.inotify;

  public struct Event {
    int wd; // watch descriptor
    uint mask; // watch event set
    uint cookie;
    string path;
    string toString() {
      import std.array : appender;
      import std.conv;

      auto buf = appender!string();
      buf.put("{wd:");
      buf.put(wd.to!string);
      buf.put(`,path:"`);
      buf.put(path);
      buf.put(`",mask:`);
      buf.put(mask.to!string);
      buf.put(`,events:"`);
      buf.put(eventNames(mask));
      buf.put(`",cookie:`);
      buf.put(cookie.to!string);
      buf.put("}");
      return buf.data;
    }
  }

  string eventNames(uint events, char sep = ',') {
    import std.array : appender;
    import std.conv;

    auto buf = appender!string();
    if (IN_ACCESS & events) {
      buf.put(sep);
      buf.put("ACCESS");
    }
    if (IN_MODIFY & events) {
      buf.put(sep);
      buf.put("MODIFY");
    }
    if (IN_ATTRIB & events) {
      buf.put(sep);
      buf.put("ATTRIB");
    }
    if (IN_CLOSE_WRITE & events) {
      buf.put(sep);
      buf.put("CLOSE_WRITE");
    }
    if (IN_CLOSE_NOWRITE & events) {
      buf.put(sep);
      buf.put("CLOSE_NOWRITE");
    }
    if (IN_OPEN & events) {
      buf.put(sep);
      buf.put("OPEN");
    }
    if (IN_MOVED_FROM & events) {
      buf.put(sep);
      buf.put("MOVED_FROM");
    }
    if (IN_MOVED_TO & events) {
      buf.put(sep);
      buf.put("MOVED_TO");
    }
    if (IN_CREATE & events) {
      buf.put(sep);
      buf.put("CREATE");
    }
    if (IN_DELETE & events) {
      buf.put(sep);
      buf.put("DELETE");
    }
    if (IN_DELETE_SELF & events) {
      buf.put(sep);
      buf.put("DELETE_SELF");
    }
    if (IN_UNMOUNT & events) {
      buf.put(sep);
      buf.put("UNMOUNT");
    }
    if (IN_Q_OVERFLOW & events) {
      buf.put(sep);
      buf.put("Q_OVERFLOW");
    }
    if (IN_IGNORED & events) {
      buf.put(sep);
      buf.put("IGNORED");
    }
    if (IN_CLOSE & events) {
      buf.put(sep);
      buf.put("CLOSE");
    }
    if (IN_MOVE_SELF & events) {
      buf.put(sep);
      buf.put("MOVE_SELF");
    }
    if (IN_ISDIR & events) {
      buf.put(sep);
      buf.put("ISDIR");
    }
    if (IN_ONESHOT & events) {
      buf.put(sep);
      buf.put("ONESHOT");
    }

    return buf.data[1 .. $];
  }
} else {
  import std.array : appender;
  import std.conv;

  public struct Event {
    int wd; // watch descriptor
    uint mask; // watch event set
    uint cookie;
    string path;
    string toString() {
      auto buf = appender!string();
      buf.put("{wd:");
      buf.put(wd.to!string);
      buf.put(`,path:"`);
      buf.put(path);
      buf.put(`",mask:`);
      buf.put(mask.to!string);
      buf.put(`,events:"`);
      buf.put(eventNames(mask));
      buf.put(`",cookie:`);
      buf.put(cookie.to!string);
      buf.put("}");
      return buf.data;
    }
  }

  string eventNames(uint events, char sep = ',') {
    return "";
  }
}
