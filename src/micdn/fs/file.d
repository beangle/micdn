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

module micdn.fs.file;
/// 文件解压、权限调整等与文件系统相关的实用函数。

import std.conv;
import std.file;
import std.stdio;
import std.string;
import std.utf;
import std.zip;

import vibe.core.log;

version (Windows) {
  import core.sys.windows.winbase;
  import core.sys.windows.windef:DWORD;
  import core.sys.windows.winerror;
}

uint unzip(string zipfile, string base, string innerDir = null) {
  string prefix = innerDir;
  if (null != prefix && !prefix.endsWith("/")) {
    prefix ~= "/";
  }
  uint count = 0;
  if (exists(zipfile)) {
    auto zip = new ZipArchive(read(zipfile));
    mkdirRecurse(base);
    foreach (name, am; zip.directory) {
      if (null == prefix || name.startsWith(prefix)) {
        auto targetName = name;
        if (null != prefix && name.startsWith(prefix)) {
          targetName = targetName[prefix.length .. $];
        }
        if (targetName.endsWith("/")) {
          mkdirRecurse(base ~ "/" ~ targetName);
        } else if (targetName.length > 0) {
          auto lastSlash = targetName.lastIndexOf("/");
          if (lastSlash > 0) {
            mkdirRecurse(base ~ "/" ~ targetName[0 .. lastSlash]);
          }
          zip.expand(am);
          assert(am.expandedData.length == am.expandedSize);
          std.file.write(base ~ "/" ~ targetName, am.expandedData);
          count += 1;
        }
      }
    }
  }
  return count;
}

uint refreshUnzip(string zipfile, string base, string innerDir = null) {
  string prefix = innerDir;
  if (null != prefix && !prefix.endsWith("/")) {
    prefix ~= "/";
  }
  uint count = 0;
  if (exists(zipfile)) {
    auto zip = new ZipArchive(read(zipfile));
    mkdirRecurse(base);
    foreach (name, am; zip.directory) {
      if (null == prefix || name.startsWith(prefix)) {
        auto targetName = name;
        if (null != prefix && name.startsWith(prefix)) {
          targetName = targetName[prefix.length .. $];
        }
        if (targetName.endsWith("/")) {
          mkdirRecurse(base ~ "/" ~ targetName);
        } else if (targetName.length > 0) {
          auto lastSlash = targetName.lastIndexOf("/");
          if (lastSlash > 0) {
            mkdirRecurse(base ~ "/" ~ targetName[0 .. lastSlash]);
          }
          auto targetFile = base ~ "/" ~ targetName;
          bool spawn = true;
          if (exists(targetFile) && getSize(targetFile) == am.expandedSize) {
            spawn = false;
          }
          if (spawn) {
            zip.expand(am);
            assert(am.expandedData.length == am.expandedSize);
            std.file.write(targetFile, am.expandedData);
          }
          count += 1;
        }
      }
    }
  }
  return count;
}

/** 创建符号链接。

    Params:
        target   = 目标路径（已存在的文件或目录）
        linkPath = 符号链接的创建路径

    Throws:
        Exception 创建失败时（Windows 上需管理员权限或开启开发者模式）
*/
void makeSymlink(string target, string linkPath) {
  version (Windows) {
    enum SYMBOLIC_LINK_FLAG_DIRECTORY = 0x1;
    enum SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x2;

    uint flags = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;  // DWORD
    if (exists(target) && isDir(target)) {
      flags |= SYMBOLIC_LINK_FLAG_DIRECTORY;
    }
    if (CreateSymbolicLinkW(linkPath.toUTF16z, target.toUTF16z, flags) == 0) {
      throw new Exception("Failed to create symlink: " ~ linkPath ~ " -> " ~ target
        ~ " (error " ~ GetLastError().to!string ~ "; require Admin or Developer Mode on Windows)");
    }
  } else {
    symlink(target, linkPath);
  }
}

void setReadOnly(string dir) {
  if (!exists(dir)) {
    return;
  }
  doSetReadOnly(dir);
}

private void doSetReadOnly(string dir) {
  if (dir.isDir) {
    dir.setAttributes(octal!555);
    foreach (d; dirEntries(dir, SpanMode.shallow)) {
      if (!d.isSymlink) {
        if (d.isDir) {
          doSetReadOnly(d);
        } else {
          d.setAttributes(octal!444);
        }
      }
    }
  } else {
    dir.setAttributes(octal!444);
  }
}

void setWritable(string dir) {
  if (!exists(dir)) {
    return;
  }
  doSetWritable(dir);
}

private void doSetWritable(string dir) {
  if (dir.isDir) {
    dir.setAttributes(dir.getAttributes | octal!700);
    foreach (d; dirEntries(dir, SpanMode.breadth)) {
      if (!d.isSymlink) {
        if (d.isDir) {
          doSetWritable(d);
        } else {
          d.setAttributes(d.getAttributes | octal!200);
        }
      }
    }
  } else {
    dir.setAttributes(dir.getAttributes | octal!600);
  }
}

