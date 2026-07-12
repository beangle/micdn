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
import std.datetime;
import std.file;
import std.path;
import std.stdio;
import std.string;
import std.utf;
import std.zip;
import std.algorithm;

import vibe.core.log;

/// ZIP 文件魔数：PK\x03\x04 本地文件头、PK\x05\x06 空/结尾、PK\x07\x08 分卷
enum zipSignature1 = "\x50\x4B\x03\x04"; // 最常见
enum zipSignature2 = "\x50\x4B\x05\x06"; // 空 zip / 中央目录结尾
enum zipSignature3 = "\x50\x4B\x07\x08"; // 分卷归档
enum zipEntryForbiddenChars = "\0\\<>:\"|?*";
enum maxZipEntryNameLength = 1024;
enum maxZipEntryPathDepth = 64;
enum maxZipEntryPartLength = 255;
enum maxZipEntryCount = 20_000;
enum maxZipCompressionRatio = 100;

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

/// 校验 zip/jar 内条目名，避免目录逃逸、跨平台非法文件名，以及超长/超深路径炸弹。
bool isSafeZipEntryTargetName(string targetName) {
  if (targetName.length == 0 || targetName.length > maxZipEntryNameLength)
    return false;
  if (targetName.any!(c => zipEntryForbiddenChars.indexOf(c) >= 0))
    return false;
  if (isAbsolute(targetName))
    return false;

  size_t depth = 0;
  auto parts = targetName.split("/");
  foreach (i, part; parts) {
    // 末尾是 / 表示目录
    bool trailingDirectorySlash = i + 1 == parts.length && part.length == 0 && targetName.endsWith("/");
    if (trailingDirectorySlash)
      continue;
    if (part.length == 0 || part.length > maxZipEntryPartLength)
      return false;
    if (part == "." || part == "..")
      return false;
    depth++;
    if (depth > maxZipEntryPathDepth)
      return false;
  }
  return true;
}

/// 判断单个条目的解压膨胀比例是否在允许范围内，避免高压缩比 zip 炸弹。
bool isSafeZipCompressionRatio(ulong expandedSize, ulong compressedSize) {
  if (expandedSize == 0)
    return true;
  if (compressedSize == 0)
    return false;
  auto q = expandedSize / compressedSize;
  auto r = expandedSize % compressedSize;
  return q < maxZipCompressionRatio || (q == maxZipCompressionRatio && r == 0);
}

/// 解压前扫描目录元数据，超过 entry 数量或压缩比限制时整包拒绝，避免只解出一部分。
private bool validateZipArchiveEntries(ZipArchive zip, string zipfile, string prefix, out uint entryCount) {
  entryCount = 0;
  foreach (name, am; zip.directory) {
    if (null == prefix || name.startsWith(prefix)) {
      auto targetName = name;
      if (null != prefix && prefix.length > 0 && name.startsWith(prefix))
        targetName = targetName[prefix.length .. $];
      if (targetName.length == 0)
        continue;
      entryCount++;
      if (entryCount > maxZipEntryCount) {
        logWarn("Skip zip %s: too many entries under %s", zipfile, prefix);
        return false;
      }
      if (!isSafeZipCompressionRatio(am.expandedSize, am.compressedSize)) {
        logWarn("Skip zip %s: entry %s compression ratio is too high", zipfile, name);
        return false;
      }
    }
  }
  return true;
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
    if (!validateZipArchiveEntries(zip, zipfile, prefix, count))
      return 0;
    count = 0;
    mkdirRecurse(base);
    foreach (name, am; zip.directory) {
      if (null == prefix || name.startsWith(prefix)) {
        auto targetName = name;
        if (null != prefix && name.startsWith(prefix)) {
          targetName = targetName[prefix.length .. $];
        }
        if (targetName.length == 0)
          continue;
        if (!isSafeZipEntryTargetName(targetName)) {
          logWarn("Skip unsafe zip entry %s in %s", name, zipfile);
          continue;
        }
        if (targetName.endsWith("/")) {
          mkdirRecurse(base ~ "/" ~ targetName);
        } else {
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

enum deployManifestFileName = "manifest.json";

private struct DeployManifest {
  uint fileCount;
  string inner;
  string artifact;
  ulong size;
  SysTime mtime;
}

private string normalizeInnerForManifest(string innerDir) {
  if (innerDir is null || innerDir.length == 0)
    return "";
  auto s = innerDir;
  while (s.endsWith("/"))
    s = s[0 .. $ - 1];
  return s;
}

private bool readDeployManifest(string path, ref DeployManifest manifest) {
  import std.json : JSONType, parseJSON;
  import std.datetime : SysTime;

  if (!exists(path))
    return false;
  try {
    auto root = parseJSON(readText(path));
    if (root.type != JSONType.object)
      return false;
    if (root["source"].type != JSONType.object)
      return false;
    auto source = root["source"];
    if (source["inner"].type != JSONType.string)
      return false;
    if (source["size"].type != JSONType.integer)
      return false;
    if (source["mtime"].type != JSONType.string)
      return false;
    if (source["fileCount"].type != JSONType.integer)
      return false;

    manifest.inner = source["inner"].str;
    manifest.size = source["size"].integer.to!ulong;
    manifest.mtime = SysTime.fromISOExtString(source["mtime"].str);
    manifest.fileCount = source["fileCount"].integer.to!uint;
    manifest.artifact = root["artifact"].type == JSONType.string ? root["artifact"].str : "";
    return true;
  } catch (Exception) {
    return false;
  }
}

private void writeDeployManifest(string base, string sourceFile, string innerDir, string artifact,
    uint fileCount) {
  import std.datetime : Clock;
  import std.json : JSONValue, toJSON;

  auto inner = normalizeInnerForManifest(innerDir);
  auto mtime = timeLastModified(sourceFile);
  auto size = getSize(sourceFile);

  JSONValue root = JSONValue.emptyObject;
  root["deployedAt"] = JSONValue(Clock.currTime().toISOExtString());
  if (artifact.length > 0)
    root["artifact"] = JSONValue(artifact);

  JSONValue source = JSONValue.emptyObject;
  source["inner"] = JSONValue(inner);
  source["size"] = JSONValue(size.to!long);
  source["mtime"] = JSONValue(mtime.toISOExtString());
  source["fileCount"] = JSONValue(fileCount);
  root["source"] = source;

  auto manifestPath = buildPath(base, deployManifestFileName);
  auto tmpPath = buildPath(base, ".manifest.json.tmp");
  std.file.write(tmpPath, toJSON(root));
  if (exists(manifestPath))
    remove(manifestPath);
  rename(tmpPath, manifestPath);
}

private bool canSkipDeployManifest(string sourceFile, string base, string innerDir, string artifact) {
  DeployManifest manifest;
  auto manifestPath = buildPath(base, deployManifestFileName);
  if (!readDeployManifest(manifestPath, manifest))
    return false;
  if (normalizeInnerForManifest(innerDir) != manifest.inner)
    return false;
  if (!exists(sourceFile))
    return false;
  if (getSize(sourceFile) != manifest.size)
    return false;
  if (timeLastModified(sourceFile) != manifest.mtime)
    return false;
  if (artifact.length > 0 && manifest.artifact != artifact)
    return false;
  return true;
}

private string deployArtifactLabel(string sourceFile, string artifact) {
  if (artifact.length > 0)
    return artifact;
  return baseName(sourceFile);
}

private string deploySkipLabel(string sourceFile, string artifact, ref DeployManifest manifest) {
  if (artifact.length > 0)
    return artifact;
  if (manifest.artifact.length > 0)
    return manifest.artifact;
  return baseName(sourceFile);
}

/** 部署源是否可读（权限不足时 stat 仍可能成功，解压前需单独校验）。 */
private bool canReadDeploySource(string sourceFile) {
  import core.sys.posix.unistd : access, R_OK;
  import std.string : toStringz;

  if (!exists(sourceFile))
    return false;
  return access(toStringz(sourceFile), R_OK) == 0;
}

/** 将 tgz（npm 包）解压到 docBase；成功后写入 `{docBase}/manifest.json`，tgz 未变时可跳过解压。

    manifest 有效则跳过；否则删除 docBase 后全量解压。

    Params:
        tgzFile  = .tgz 文件路径
        docBase  = 目标目录（最终挂载内容所在）
        innerDir = tgz 内相对路径（如 `package/lib`），null 或空表示解压到 docBase 根
        artifact = 可选逻辑产物标识（如 `wujie@2.1.0`）
        force    = true 时删除 docBase 后全量解压，忽略 manifest 快路径

    Returns:
        true 成功，false 失败
*/
bool extractTgzToDocBase(string tgzFile, string docBase, string innerDir = null, string artifact = null,
    bool force = false) {
  if (!exists(tgzFile))
    return false;

  if (!force && canSkipDeployManifest(tgzFile, docBase, innerDir, artifact)) {
    DeployManifest manifest;
    readDeployManifest(buildPath(docBase, deployManifestFileName), manifest);
    logInfo("Caching %s...", deploySkipLabel(tgzFile, artifact, manifest));
    return true;
  }

  logInfo("Deploying %s", deployArtifactLabel(tgzFile, artifact));
  if (!canReadDeploySource(tgzFile)) {
    logWarn("Deploy source is not readable, keeping existing deploy: %s", tgzFile);
    return false;
  }
  clearDeployDir(docBase);

  if (!extractTgzToDocBaseImpl(tgzFile, docBase, innerDir))
    return false;
  writeDeployManifest(docBase, tgzFile, innerDir, artifact, 1);
  return true;
}

private bool extractTgzToDocBaseImpl(string tgzFile, string docBase, string innerDir = null) {
  if (!exists(tgzFile))
    return false;

  if (null == innerDir || innerDir.length == 0) {
    if (exists(docBase))
      rmdirRecurse(docBase);
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

  const extractAbs = absolutePath(extractDir);
  const sourceDir = buildNormalizedPath(extractAbs, innerDir);
  if (!isPathUnder(extractAbs, sourceDir)) {
    logWarn("innerDir escapes extract dir: %s", innerDir);
    return false;
  }
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

private string innerDirPrefix(string innerDir) {
  if (innerDir is null || innerDir.length == 0)
    return null;
  auto prefix = innerDir;
  if (!prefix.endsWith("/"))
    prefix ~= "/";
  return prefix;
}

/** 解压 zip/jar 到 base；成功后写入 `{base}/manifest.json`，源文件未变时可跳过整包解压。

    manifest 有效则跳过；否则删除 base 后全量解压（不做逐文件 CRC/大小比对）。

    Params:
        zipfile  = zip/jar 文件路径
        base     = 目标解压根目录
        innerDir = zip 内要解压的子目录，null 表示全部
        artifact = 可选逻辑产物标识（如 GAV），写入 manifest 并参与快路径校验
        force    = true 时忽略 manifest 快路径

    Returns:
        解压的文件 entry 数量
*/
uint refreshUnzip(string zipfile, string base, string innerDir = null, string artifact = null,
    bool force = false) {
  if (!force && canSkipDeployManifest(zipfile, base, innerDir, artifact)) {
    DeployManifest manifest;
    readDeployManifest(buildPath(base, deployManifestFileName), manifest);
    logInfo("Caching %s...", deploySkipLabel(zipfile, artifact, manifest));
    return manifest.fileCount;
  }

  logInfo("Deploying %s", deployArtifactLabel(zipfile, artifact));
  if (!canReadDeploySource(zipfile)) {
    logWarn("Deploy source is not readable, keeping existing deploy: %s", zipfile);
    return 0;
  }
  clearDeployDir(base);

  auto count = refreshUnzipImpl(zipfile, base, innerDir);
  if (count > 0)
    writeDeployManifest(base, zipfile, innerDir, artifact, count);
  return count;
}

private uint refreshUnzipImpl(string zipfile, string base, string innerDir = null) {
  string prefix = innerDirPrefix(innerDir);
  uint count = 0;
  if (!exists(zipfile))
    return 0;
  if (!isZipFile(zipfile)) {
    logWarn("Not a valid zip file (bad magic): %s", zipfile);
    return 0;
  }
  try {
    auto zip = new ZipArchive(read(zipfile));
    if (!validateZipArchiveEntries(zip, zipfile, prefix, count))
      return 0;
    count = 0;
    mkdirRecurse(base);
    foreach (name, am; zip.directory) {
      if (null == prefix || name.startsWith(prefix)) {
        auto targetName = name;
        if (null != prefix && prefix.length > 0 && name.startsWith(prefix)) {
          targetName = targetName[prefix.length .. $];
        }
        if (targetName.length == 0)
          continue;
        if (targetName == deployManifestFileName) {
          continue;
        }
        if (!isSafeZipEntryTargetName(targetName)) {
          logWarn("Skip unsafe zip entry %s in %s", name, zipfile);
          continue;
        }
        if (targetName.endsWith("/")) {
          mkdirRecurse(base ~ "/" ~ targetName);
        } else {
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

/** 删除部署目录（符号链接仅 remove，目录则递归删除）。供 `deploy --force` 使用。 */
void clearDeployDir(string dir) {
  if (!exists(dir))
    return;
  logInfo("Removing %s", dir);
  if (isSymlink(dir))
    remove(dir);
  else
    rmdirRecurse(dir);
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

/** 仅将目录本身设为可写（目录 +700，不递归子项、不修改符号链接）。

    static / www 的 `prepareBase` 在 build 与 `deploy` 前调用，保证能在 base 下
    新建 bundle / doc 子目录；子项权限沿用现有文件或解压结果。
*/
void ensureDirWritable(string dir) {
  if (exists(dir) && dir.isDir)
    dir.setAttributes(dir.getAttributes | octal!700);
}

/** 确保目录存在，并探测当前进程能否在其中创建文件（挂载前校验用）。 */
bool verifyDeployDirWritable(string dir) {
  if (dir.length == 0)
    return false;
  try {
    mkdirRecurse(dir);
    if (!exists(dir) || !isDir(dir))
      return false;
    auto probe = buildPath(dir, ".micdn-write-probe");
    std.file.write(probe, "");
    remove(probe);
    return true;
  } catch (Exception) {
    return false;
  }
}

/** 递归将目录及子项设为只读（目录 555，文件 444），符号链接不修改。

    保留供测试或手工维护场景使用；micdn 的 static / www build 与 deploy 不再调用。
    与 `setWritable` 成对，可整树锁定后再整树恢复可写。
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

    保留供测试或手工维护场景使用；micdn 的 static / www 改用 `ensureDirWritable`
    只对 base 目录本身 chmod，避免 deploy 时对大目录树递归 chmod。
    与 `setReadOnly` 成对。
*/
void setWritable(string dir) {
  if (!exists(dir)) {
    return;
  }
  doSetWritable(dir);
}

/** 路径按 `/` 分段后不得含空段、`.` 或 `..`。

    用于配置中的 endpoint（如 www `<doc location>`）、归档内子路径等，不替代 HTTP 侧的 `decodeRepositoryUri`。
*/
bool isSafePathSegments(in string path) @safe pure {
  if (path is null || path.length == 0)
    return false;
  foreach (i, part; path.split("/")) {
    if (part.length == 0) {
      if (i == 0 && path[0] == '/')
        continue;
      return false;
    }
    if (part == "." || part == "..")
      return false;
  }
  return true;
}

/** 判断规范化后的 `absPath` 是否位于 `absDir` 下（含与 `absDir` 相等）。

    假定两路径已为绝对路径；纯字符串前缀比较，不访问磁盘。
    Windows 下比较不区分大小写。用于仓库根目录、xi:include 基目录等防穿越校验。
*/
bool isPathUnder(const string absDir, const string absPath) {
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
