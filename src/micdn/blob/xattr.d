/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.blob.xattr;
/// Blob 文件元数据存放在扩展属性 `user.*`（Linux）；非 Linux 平台为占位实现。

import std.string;

version (linux) {
  import core.sys.linux.sys.xattr;
  import core.sys.posix.sys.types : ssize_t;

  /// 写入 blob 常用 user.* 属性（owner、sha1、original_name）。媒体类型与更新时间由扩展名与文件 mtime 推导，不存 xattr。
  void setBlobUserMeta(string physicalPath, string owner, string sha1, string name) {
    setUserXattr(physicalPath, "owner", owner);
    setUserXattr(physicalPath, "sha1", sha1);
    setUserXattr(physicalPath, "original_name", name);
  }

  void setUserXattr(string path, string shortName, string value) {
    import std.string : toStringz;

    string full = "user." ~ shortName;
    setxattr(toStringz(path), toStringz(full), value.ptr, value.length, 0);
  }

  string getUserXattr(string path, string shortName) {
    import std.string : toStringz;

    string full = "user." ~ shortName;
    ssize_t sz = getxattr(toStringz(path), toStringz(full), null, 0);
    if (sz <= 0)
      return "";
    ubyte[] buf = new ubyte[cast(size_t) sz];
    ssize_t r = getxattr(toStringz(path), toStringz(full), cast(void*) buf.ptr, buf.length);
    if (r <= 0)
      return "";
    return cast(string) buf[0 .. r].idup;
  }

  /// 列出路径上所有 `user.*` 名与值，供通知 JSON 的扩展字段。
  string[string] listUserXattrs(string path) {
    import std.string : toStringz;

    string[string] out_;
    ssize_t sz = listxattr(toStringz(path), null, 0);
    if (sz <= 0)
      return out_;
    char[] buf = new char[cast(size_t) sz];
    ssize_t r = listxattr(toStringz(path), buf.ptr, buf.length);
    if (r <= 0)
      return out_;
    size_t i = 0;
    while (i < cast(size_t) r) {
      size_t j = i;
      while (j < cast(size_t) r && buf[j] != 0)
        j++;
      if (j > i) {
        string part = cast(string) buf[i .. j].idup;
        if (part.startsWith("user.")) {
          string shortName = part["user.".length .. $];
          out_[shortName] = getUserXattr(path, shortName);
        }
      }
      i = j + 1;
    }
    return out_;
  }
} else {
  void setBlobUserMeta(string physicalPath, string owner, string sha1, string name) {
  }

  void setUserXattr(string path, string shortName, string value) {
  }

  string getUserXattr(string path, string shortName) {
    return "";
  }

  string[string] listUserXattrs(string path) {
    string[string] empty;
    return empty;
  }
}
