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

module micdn.fs.tar;
/// tar/tgz 解压：内置 gzip + tar 解析，不依赖宿主 tar 命令。

import std.algorithm;
import std.conv;
import std.file;
import std.path;
import std.stdio;
import std.string;
import std.zlib : UnCompress, HeaderFormat;

import vibe.core.log;

/// tar 条目名长度/深度上限（与 zip 侧口径一致）。
enum maxTarEntryNameLength = 1024;
enum maxTarEntryPathDepth = 64;
enum maxTarEntryPartLength = 255;

/// tgz 解压后 tar 条目数上限（与 zip 侧口径一致）。
enum size_t maxTgzEntryCount = 20_000;
/// gzip 解压后（tar 内容）总字节上限，防御解压炸弹。
enum ulong maxTgzDecompressedSize = 2UL * 1024 * 1024 * 1024;

/// absPath 是否位于 absDir 之下（或相等）；两侧都应是规范化绝对路径。
private bool pathUnder(const string absDir, const string absPath) {
  import std.path : dirSeparator;
  version (Windows) {
    auto dir = absDir.toLower();
    auto path = absPath.toLower();
  } else {
    auto dir = absDir;
    auto path = absPath;
  }

  if (path == dir)
    return true;
  if (path.length <= dir.length)
    return false;
  if (path[dir.length] != dirSeparator[0])
    return false;
  return path.startsWith(dir);
}

/** 使用内置 gzip + tar 解析解压 tgz 到指定目录（不再依赖宿主 tar 命令）。

    与 zip 侧同样的安全口径：解压前检查 gzip 魔数，解压时限制总大小，
    逐条目校验路径合法性（拒绝绝对路径、`..` 穿越与超深/超长），
    并防止经由本包内先创建的符号链接写入 baseDir 之外。

    Params:
        tgzFile = .tgz 文件路径
        baseDir = 解压目标目录

    Returns:
        true 成功，false 失败（损坏、超限或不安全条目）
*/
bool extractTgz(string tgzFile, string baseDir) {
  if (!exists(tgzFile))
    return false;

  ubyte[] data;
  try {
    auto f = File(tgzFile, "rb");
    scope (exit)
      f.close();

    ubyte[2] magic;
    if (f.rawRead(magic[]).length < 2 || magic[0] != 0x1F || magic[1] != 0x8B) {
      logWarn("Not a valid tgz (bad gzip magic): %s", tgzFile);
      return false;
    }
    f.rewind();

    auto uz = new UnCompress(HeaderFormat.gzip);
    ubyte[64 * 1024] chunk;
    ulong total;
    while (true) {
      auto n = f.rawRead(chunk[]).length;
      if (n == 0)
        break;
      auto decoded = cast(ubyte[]) uz.uncompress(chunk[0 .. n]);
      total += decoded.length;
      if (total > maxTgzDecompressedSize) {
        logWarn("Skip tgz %s: decompressed size exceeds limit", tgzFile);
        return false;
      }
      data ~= decoded;
    }
  } catch (Exception e) {
    logError("Invalid or corrupted tgz: %s - %s", tgzFile, e.msg);
    return false;
  }

  mkdirRecurse(baseDir);
  try {
    return extractTarEntries(data, baseDir, tgzFile);
  } catch (Exception e) {
    logError("Invalid or corrupted tgz: %s - %s", tgzFile, e.msg);
    return false;
  }
}

private struct TarHeader {
  char[100] name;
  char[8] mode;
  char[8] uid;
  char[8] gid;
  char[12] size;
  char[12] mtime;
  char[8] chksum;
  char[1] typeflag;
  char[100] linkname;
  char[6] magic;
  char[2] ver;
  char[32] uname;
  char[32] gname;
  char[8] devmajor;
  char[8] devminor;
  char[155] prefix;
  char[12] pad;
}

/// 取 tar 头部文本字段（到首个 NUL 为止，并剥掉旧式空格填充）。
private string tarFieldString(const(char)[] field) {
  size_t end;
  foreach (i, c; field) {
    if (c == 0) {
      end = i;
      break;
    }
    end = i + 1;
  }
  auto s = cast(string) field[0 .. end];
  while (s.length > 0 && s[$ - 1] == ' ')
    s = s[0 .. $ - 1];
  return s;
}

/// 解析 tar 八进制数字字段（支持前导空格、NUL 填充与 GNU base-256 大数）。
private ulong tarOctalValue(const(char)[] field) {
  auto s = tarFieldString(field);
  if (s.length == 0)
    return 0;
  if ((s[0] & 0x80) != 0) {
    auto b = cast(ubyte[]) s;
    ulong v = b[0] & 0x3F;
    foreach (i; 1 .. b.length)
      v = (v << 8) | b[i];
    return v;
  }
  ulong v;
  foreach (c; s) {
    if (c == ' ' || c == '\t')
      continue;
    if (c < '0' || c > '7')
      break;
    v = v * 8 + (c - '0');
  }
  return v;
}

private bool isZeroTarHeader(ref TarHeader hdr) {
  auto p = cast(const(ubyte)*) &hdr;
  foreach (i; 0 .. TarHeader.sizeof)
    if (p[i] != 0)
      return false;
  return true;
}

private bool validTarChecksum(ref TarHeader hdr) {
  auto p = cast(const(ubyte)*) &hdr;
  uint sumSpaces, sumZero;
  foreach (i; 0 .. TarHeader.sizeof) {
    auto b = p[i];
    if (i >= 148 && i < 156) {
      sumSpaces += 0x20;
      sumZero += 0;
    } else {
      sumSpaces += b;
      sumZero += b;
    }
  }
  auto given = tarOctalValue(hdr.chksum);
  return given == sumSpaces || given == sumZero;
}

/// tar 条目名合法性：拒绝绝对路径、空段、`.`/`..`、超长/超深（对齐 zip 侧口径）。
private bool isSafeTgzEntryName(string name) {
  if (name.length == 0 || name.length > maxTarEntryNameLength)
    return false;
  if (isAbsolute(name))
    return false;
  if (name.length >= 2 && name[1] == ':')
    return false;
  size_t depth;
  foreach (part; name.split("/")) {
    if (part.length == 0 || part == "." || part == "..")
      return false;
    if (part.length > maxTarEntryPartLength)
      return false;
    depth++;
    if (depth > maxTarEntryPathDepth)
      return false;
  }
  return true;
}

/// 目标父链上不能有符号链接（防止经本包内先建的链接逃逸写穿 baseDir）。
private bool safeWriteDirChain(const string baseAbs, const string dir, string tgzFile, string entryName) {
  string cur = dir;
  while (cur.length >= baseAbs.length) {
    if (cur != baseAbs && exists(cur) && isSymlink(cur)) {
      logWarn("Skip tgz entry %s: parent %s is a symlink", entryName, cur);
      return false;
    }
    if (cur == baseAbs)
      break;
    cur = dirName(cur);
  }
  mkdirRecurse(dir);
  return true;
}

/// 解析 pax 扩展头（`x`），仅提取 path / linkpath / size 覆盖项。
private void parsePaxHeader(const(ubyte)[] content, ref string paxPath, ref string paxLink,
    ref ulong paxSize, ref bool hasPath, ref bool hasLink, ref bool hasSize) {
  size_t off;
  while (off < content.length) {
    auto sp = off;
    while (sp < content.length && content[sp] != ' ')
      sp++;
    if (sp >= content.length)
      break;
    ulong len;
    foreach (i; off .. sp) {
      auto c = content[i];
      if (c < '0' || c > '9')
        break;
      len = len * 10 + (c - '0');
    }
    if (len == 0 || off + len > content.length)
      break;
    auto rec = cast(string) content[sp + 1 .. off + len];
    if (rec.length > 0 && rec[$ - 1] == '\n')
      rec = rec[0 .. $ - 1];
    auto eq = rec.indexOf('=');
    if (eq >= 0) {
      auto key = rec[0 .. eq];
      auto value = rec[eq + 1 .. $];
      if (key == "path") {
        paxPath = value;
        hasPath = true;
      } else if (key == "linkpath") {
        paxLink = value;
        hasLink = true;
      } else if (key == "size") {
        paxSize = to!ulong(value);
        hasSize = true;
      }
    }
    off += len;
  }
}

/// 解析 tar 内容为 baseDir 下文件树；失败返回 false 并记日志。
private bool extractTarEntries(const(ubyte)[] data, string baseDir, string tgzFile) {
  const baseAbs = buildNormalizedPath(absolutePath(baseDir));
  size_t off;
  uint count;
  ulong written;
  string gnuName, gnuLink;
  string paxPath, paxLink;
  ulong paxSize;
  bool paxHasPath, paxHasLink, paxHasSize;

  while (off + TarHeader.sizeof <= data.length) {
    auto hdr = cast(TarHeader*) (data.ptr + off);
    off += TarHeader.sizeof;

    if (isZeroTarHeader(*hdr))
      break;
    if (!validTarChecksum(*hdr)) {
      logWarn("Invalid tar checksum in %s", tgzFile);
      return false;
    }

    auto type = hdr.typeflag[0];
    auto size = tarOctalValue(hdr.size);
    if (off + size > data.length) {
      logWarn("Truncated tar entry in %s", tgzFile);
      return false;
    }

    if (type == 'x' || type == 'g') {
      if (type == 'x')
        parsePaxHeader(data[off .. off + size], paxPath, paxLink, paxSize, paxHasPath, paxHasLink, paxHasSize);
      off += (size + 511) & ~511UL;
      continue;
    }
    if (type == 'L' || type == 'K') {
      auto content = data[off .. off + size];
      size_t end;
      foreach (i, b; content) {
        if (b == 0) {
          end = i;
          break;
        }
        end = i + 1;
      }
      if (type == 'L')
        gnuName = cast(string) content[0 .. end];
      else
        gnuLink = cast(string) content[0 .. end];
      off += (size + 511) & ~511UL;
      continue;
    }

    string entryName = tarFieldString(hdr.name);
    auto prefix = tarFieldString(hdr.prefix);
    if (prefix.length > 0)
      entryName = prefix ~ "/" ~ entryName;
    if (gnuName.length > 0) {
      entryName = gnuName;
      gnuName = null;
    }
    if (paxHasPath) {
      entryName = paxPath;
      paxHasPath = false;
    }
    string entryLink = tarFieldString(hdr.linkname);
    if (gnuLink.length > 0) {
      entryLink = gnuLink;
      gnuLink = null;
    }
    if (paxHasLink) {
      entryLink = paxLink;
      paxHasLink = false;
    }
    if (paxHasSize) {
      size = paxSize;
      paxHasSize = false;
    }

    auto checkName = entryName;
    while (checkName.length > 0 && checkName[$ - 1] == '/')
      checkName = checkName[0 .. $ - 1];
    if (checkName.length == 0 || !isSafeTgzEntryName(checkName)) {
      logWarn("Skip unsafe tgz entry %s in %s", entryName, tgzFile);
      return false;
    }
    auto target = buildNormalizedPath(baseAbs, entryName);
    if (!pathUnder(baseAbs, target)) {
      logWarn("Skip tgz entry escaping base dir %s in %s", entryName, tgzFile);
      return false;
    }
    if (count >= maxTgzEntryCount) {
      logWarn("Skip tgz %s: too many entries", tgzFile);
      return false;
    }

    switch (type) {
      case '\0', '0', '7': // 普通文件
        if (size > maxTgzDecompressedSize - written) {
          logWarn("Skip tgz %s: total size exceeds limit", tgzFile);
          return false;
        }
        written += size;
        if (!safeWriteDirChain(baseAbs, dirName(target), tgzFile, entryName))
          return false;
        if (exists(target)) {
          if (isDir(target))
            rmdirRecurse(target);
          else
            remove(target);
        }
        std.file.write(target, data[off .. off + size]);
        applyTarMode(target, hdr.mode);
        count++;
        break;
      case '5': // 目录
        mkdirRecurse(target);
        applyTarMode(target, hdr.mode);
        count++;
        break;
      case '2': { // 符号链接
        if (!safeWriteDirChain(baseAbs, dirName(target), tgzFile, entryName))
          return false;
        if (exists(target))
          remove(target);
        version (Posix) {
          import core.sys.posix.unistd : symlink;
          import std.string : toStringz;
          if (symlink(toStringz(entryLink), toStringz(target)) != 0) {
            logWarn("Failed to create symlink %s in %s", entryName, tgzFile);
            return false;
          }
        } else {
          logWarn("Skip tgz symlink %s: not supported on this platform", entryName);
          return false;
        }
        count++;
        break;
      }
      case '1': { // 硬链接
        auto linkTarget = buildNormalizedPath(baseAbs, entryLink);
        if (!pathUnder(baseAbs, linkTarget) || !exists(linkTarget) || isDir(linkTarget)) {
          logWarn("Skip tgz hardlink %s -> %s in %s", entryName, entryLink, tgzFile);
          return false;
        }
        if (!safeWriteDirChain(baseAbs, dirName(target), tgzFile, entryName))
          return false;
        if (exists(target))
          remove(target);
        version (Posix) {
          import core.sys.posix.unistd : link;
          import std.string : toStringz;
          if (link(toStringz(linkTarget), toStringz(target)) != 0) {
            logWarn("Failed to create hardlink %s in %s", entryName, tgzFile);
            return false;
          }
        } else {
          logWarn("Skip tgz hardlink %s: not supported on this platform", entryName);
          return false;
        }
        count++;
        break;
      }
      default: // 设备/管道等特殊条目：跳过内容，不创建
        break;
    }
    off += (size + 511) & ~511UL;
  }
  return true;
}

/// 按 tar 头部 mode 设置文件/目录权限（仅 POSIX 有意义；失败仅告警不中止）。
private void applyTarMode(string path, const(char)[] modeField) {
  version (Posix) {
    auto mode = tarOctalValue(modeField) & octal!7777;
    if (mode == 0)
      return;
    try {
      std.file.setAttributes(path, cast(uint) mode);
    } catch (Exception e) {
      logWarn("Failed to set mode on %s: %s", path, e.msg);
    }
  }
}
