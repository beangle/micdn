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
import std.path;
import std.stdio;
import std.string;
import std.utf;
import std.zip;

import vibe.core.log;

/// ZIP 文件魔数：PK\x03\x04 本地文件头、PK\x05\x06 空/结尾、PK\x07\x08 分卷
enum zipSignature1 = "\x50\x4B\x03\x04"; // 最常见
enum zipSignature2 = "\x50\x4B\x05\x06"; // 空 zip / 中央目录结尾
enum zipSignature3 = "\x50\x4B\x07\x08"; // 分卷归档

/** 通过魔数快速判断是否为合法 ZIP 文件，仅读取前 4 字节。

    不保证文件完整可解压，深度校验由 ZipArchive 构造时完成。
    用于在 read() 全量加载前快速拒绝明显非 zip 的文件。

    Params:
        zipfile = 文件路径

    Returns:
        true 若前 4 字节为 ZIP 标准签名之一
*/
bool isZipFile(string zipfile) {
  if (!exists(zipfile))
    return false;
  auto f = File(zipfile, "rb");
  scope (exit)
    f.close();
  ubyte[4] buf;
  auto readBuf = f.rawRead(buf[]);
  if (readBuf.length < 4)
    return false;
  auto s = cast(string) readBuf;
  return s == zipSignature1 || s == zipSignature2 || s == zipSignature3;
}

version (Windows) {
  import core.sys.windows.winbase;
  import core.sys.windows.windef : DWORD;
  import core.sys.windows.winerror;
}

/** 将 zip/jar 包解压到指定目录。

    若指定 innerDir，则仅解压该子目录内的条目；否则解压全部。
    目录条目会创建空目录，文件条目会写入磁盘。

    Params:
        zipfile  = zip/jar 文件路径
        base     = 目标解压根目录
        innerDir = zip 内要解压的子目录（如 "META-INF/resources"），null 表示全部

    Returns:
        实际解压的文件数量（不含目录）
*/
uint unzip(string zipfile, string base, string innerDir = null) {
  string prefix = innerDir;
  if (null != prefix && !prefix.endsWith("/")) {
    prefix ~= "/";
  }
  uint count = 0;
  if (!exists(zipfile))
    return 0;
  if (!isZipFile(zipfile)) {
    logWarn("Not a valid zip file (bad magic): %s", zipfile);
    return 0;
  }
  try {
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
  } catch (ZipException e) {
    logError("Invalid or corrupted zip file: %s - %s", zipfile, e.msg);
    return 0;
  }
  return count;
}

/** 使用系统命令 tar -xzf 解压 tgz 到指定目录，解压后包内有一层 package/ 目录。

    Params:
        tgzFile = .tgz 文件路径
        baseDir = 解压目标目录

    Returns:
        0 表示失败，1 表示成功（不统计文件数）
*/
bool doExtractTgz(string tgzFile, string baseDir) {
  if (!exists(tgzFile))
    return 0;
  mkdirRecurse(baseDir);
  import std.process;

  auto result = execute(["tar", "-xzf", tgzFile, "-C", baseDir]);
  return result.status == 0;
}

/** 将 tgz（npm 包）解压到临时目录，再按 innerDir 搬到 docBase。

    先解压到 docBase_npm_extract，npm 包内有一层 package/ 目录。
    若 innerDir 为 null 或空，将 package/ 整体 rename 为 docBase；
    若 innerDir 非空，将 package/innerDir 整个 mv 到 docBase。
    最后删除临时目录。

    Params:
        tgzFile  = .tgz 文件路径
        docBase  = 目标目录（最终挂载内容所在）
        innerDir = npm 包内子目录（如 "dist"），null 或空表示使用 package 根

    Returns:
        true 成功，false 失败
*/
bool extractTgzToDocBase(string tgzFile, string docBase, string innerDir = null) {
  if (!exists(tgzFile))
    return false;

  if (null == innerDir || innerDir.length == 0) {
    return doExtractTgz(tgzFile, docBase);
  }

  auto extractDir = docBase ~ "_tgz_extract";
  scope (exit) {
    if (exists(extractDir))
      rmdirRecurse(extractDir);
  }

  if (exists(extractDir))
    rmdirRecurse(extractDir);

  if (!doExtractTgz(tgzFile, extractDir))
    return false;

  string sourceDir = extractDir ~ "/" ~ innerDir;
  if (!exists(sourceDir) || !isDir(sourceDir)) {
    logWarn("Cannot find %s in %s", innerDir, tgzFile);
    return false;
  }

  if (exists(docBase)) {
    rmdirRecurse(docBase);
  }
  mkdirRecurse(dirName(docBase));
  rename(sourceDir, docBase);
  return true;
}

/** 增量解压 zip/jar：已存在且大小一致的文件跳过写入，用于加速重复构建。

    逻辑与 unzip 相同，但会检查目标文件是否存在且大小等于 zip 内条目大小，
    满足则跳过解压，否则覆盖写入。

    Params:
        zipfile  = zip/jar 文件路径
        base     = 目标解压根目录
        innerDir = zip 内要解压的子目录，null 表示全部

    Returns:
        匹配的文件数量（含跳过的）
*/
uint refreshUnzip(string zipfile, string base, string innerDir = null) {
  string prefix = innerDir;
  if (null != prefix && prefix.length > 0 && !prefix.endsWith("/")) {
    prefix ~= "/";
  }
  uint count = 0;
  if (!exists(zipfile))
    return 0;
  if (!isZipFile(zipfile)) {
    logWarn("Not a valid zip file (bad magic): %s", zipfile);
    return 0;
  }
  try {
    auto zip = new ZipArchive(read(zipfile));
    mkdirRecurse(base);
    foreach (name, am; zip.directory) {
      if (null == prefix || name.startsWith(prefix)) {
        auto targetName = name;
        if (null != prefix && prefix.length > 0 && name.startsWith(prefix)) {
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
  } catch (ZipException e) {
    logError("Invalid or corrupted zip file: %s - %s", zipfile, e.msg);
    return 0;
  }
  return count;
}

/** 创建符号链接。

    先对 target 做 expandTilde 展开 ~，若仍为相对路径则转为基于当前工作目录的绝对路径。
    确保符号链接存储绝对路径，解析时不受链接所在目录影响。

    Params:
        target   = 目标路径（已存在的文件或目录，建议使用绝对路径）
        linkPath = 符号链接的创建路径

    Throws:
        Exception 创建失败时（Windows 上需管理员权限或开启开发者模式）
*/
void makeSymlink(const string target, const string linkPath)
in {
  assert(target.length > 0, "makeSymlink: target must not be empty");
}
do {
  auto resolved = std.path.expandTilde(target);
  if (!std.path.isAbsolute(resolved)) {
    resolved = std.path.absolutePath(resolved);
  }
  version (Windows) {
    enum SYMBOLIC_LINK_FLAG_DIRECTORY = 0x1;
    enum SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x2;

    uint flags = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE; // DWORD
    if (exists(resolved) && isDir(resolved)) {
      flags |= SYMBOLIC_LINK_FLAG_DIRECTORY;
    }
    if (CreateSymbolicLinkW(linkPath.toUTF16z, resolved.toUTF16z, flags) == 0) {
      throw new Exception("Failed to create symlink: " ~ linkPath ~ " -> " ~ resolved ~ " (error " ~ GetLastError()
          .to!string ~ "; require Admin or Developer Mode on Windows)");
    }
  } else {
    symlink(resolved, linkPath);
  }
}

/** 递归将目录及子项设为只读（目录 555，文件 444），符号链接不修改。
*/
void setReadOnly(string dir) {
  if (!exists(dir)) {
    return;
  }
  doSetReadOnly(dir);
}

/// 递归设置只读的实现，符号链接跳过。
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

/** 递归将目录及子项设为可写（目录 +700，文件 +200），符号链接不修改。
    用于在覆盖/解压前恢复写入权限。
*/
void setWritable(string dir) {
  if (!exists(dir)) {
    return;
  }
  doSetWritable(dir);
}

/// 递归设置可写的实现，符号链接跳过。
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
