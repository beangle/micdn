/* Copyright (C) 2026 Beangle
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

module micdn.maven.snapshot;
/** 本地 Maven SNAPSHOT 仓库：目录布局、sha1 与 `maven-metadata.xml`（HTTP 侧见 `micdn.maven.web.MavenService`）。

    布局与正式版仓库（`GavRepo`）一致、**共用同一个 base**：`{base}/{group 路径}/{artifact}/{version}/{文件名}`，
    只是 `version` 形如 `1.0.0-SNAPSHOT`、文件名带 `mvn deploy` 生成的时间戳
    （`{artifact}-{version-without-SNAPSHOT}-{timestamp}-{build}[-{classifier}].{ext}`）。

    与 npm 侧同口径：**元数据由写入方产出**——`micdn install` 复制构件、写 `.sha1` 并扫目录合成
    `maven-metadata.xml`；HTTP 侧负责发文件、解析「不带时间戳的别名」到最新构建，不接受上传。

    入口只有一个 `/maven`：正式版与 SNAPSHOT 共用同一目录树，按版本区分，回源时由 `GavRepo` 按
    uri 是否含 `SNAPSHOT` 选择上游（见 `GavRepo.upstreamsFor`）。
*/

import std.algorithm;
import std.array;
import std.ascii : isDigit;
import std.conv;
import std.digest : toHexString;
import std.digest.sha : sha1Of;
import std.file;
import std.path;
import std.string;
import std.zip;

import dxml.dom;
import dxml.parser : EntityType;

import micdn.model;
import micdn.xml : children, parseDomRoot;
import micdn.web : normalizeBasePath;

/// 快照元数据文件名（maven 客户端据此把 `-SNAPSHOT` 版本解析成带时间戳的文件）。
enum metadataFileName = "maven-metadata.xml";
/// maven 元数据与仓库中的校验文件后缀（与 `GavRepo` 一致，只写 sha1）。
enum sha1Postfix = ".sha1";

/// 一个快照文件的坐标（从工件内部读取）。
struct SnapshotCoordinates {
  string group;
  string artifact;
  string ver;
}

/// 带时间戳的快照文件名解析结果：`{artifact}-{ver}-{timestamp}-{build}[-{classifier}].{ext}`；
/// 磁盘上的文件名用时间戳替换了 `-SNAPSHOT`（即 `ver` 去掉 `-SNAPSHOT`）。
struct SnapshotFile {
  string timestamp;
  int build;
  string classifier;
  string ext;
}

/// `installSnapshot` 的结果（供 CLI 打印与测试）。
struct SnapshotResult {
  SnapshotCoordinates coords;
  /// 落盘文件名（含时间戳）
  string fileName;
  /// 落盘绝对路径
  string file;
  /// 写出的 maven-metadata.xml 绝对路径
  string metadata;
  /// 相对 `/maven` 的 uri（以 `/` 开头）
  string uri;
}

/** SNAPSHOT 本地仓库：目录布局与正式版共用 `base`（`config.maven.base`）。

    - 构件由 `micdn install`（或运维按目录规范放入）落盘；
    - 只负责本地布局与「不带时间戳的别名 → 最新时间戳文件」的解析；回源由 `GavRepo` 负责
      （`/maven` 的 handler 同时持有两者）。
*/
class SnapshotRepo {
  /// 仓库根目录（绝对路径），与 `/maven` 共用
  const string base;

  this(string base) {
    import std.exception : enforce;

    enforce(base.length > 0, "snapshot base must not be empty");
    this.base = normalizeBasePath(base);
  }

  static SnapshotRepo build(MicdnConfig config) {
    mkdirRecurse(config.maven.base);
    return new SnapshotRepo(config.maven.base);
  }

  /// 版本目录：`{base}/{group 路径}/{artifact}/{ver}`。
  string versionDir(string group, string artifact, string ver) const {
    return base ~ "/" ~ group.replace(".", "/") ~ "/" ~ artifact ~ "/" ~ ver;
  }

  /// `/maven` 之后的相对 uri（以 `/` 开头）。
  string uriOf(string group, string artifact, string ver, string fileName) const {
    return "/" ~ group.replace(".", "/") ~ "/" ~ artifact ~ "/" ~ ver ~ "/" ~ fileName;
  }

  /** 解析「不带时间戳的别名」：`{artifact}-{ver}[-{classifier}].{ext}[.sha1]`
      → 同目录下最新的时间戳文件（返回相对 uri，无则返回 null）。

      路径形态为 `{group 路径}/{artifact}/{ver}/{文件名}`，故 artifact 与 ver 取自父目录，
      交付期不读工件内容。

      匹配规则：候选文件名去掉可选的 `.sha1` 后必须解析成快照名（`parseSnapshotName`），且
      ——除时间戳与 build 号外——与请求的 `[-{classifier}].{ext}` 完全一致（`-sources.jar` 不会
      命中 `.jar`，`.jar` 请求不会命中 `.jar.sha1`）。同一目录下取 (timestamp, build) 最大者；
      并列时保留先遇到的那个（内容等价，文件名只差 build 号的场景不会出现）。

      目录名（`ver` 不以 `-SNAPSHOT` 结尾）或路径不存在时返回 null，由调用方按普通文件处理（404）。
  */
  string latestAlias(string ruri) const {
    auto name = baseName(ruri);
    auto dir = dirName(ruri);
    auto ver = baseName(dir);
    auto artifact = baseName(dirName(dir));
    if (artifact.length == 0 || ver.length == 0 || !ver.endsWith("-SNAPSHOT"))
      return null;
    auto aliasBase = artifact ~ "-" ~ ver;
    if (!name.startsWith(aliasBase))
      return null;
    // 别名尾部：`.jar` / `-sources.jar` / `.jar.sha1` 等（版本号之后的全部内容）
    auto tail = name[aliasBase.length .. $];
    if (tail.length < 2 || (tail[0] != '.' && tail[0] != '-'))
      return null;
    auto stampPrefix = artifact ~ "-" ~ ver[0 .. $ - "-SNAPSHOT".length] ~ "-";
    auto wantSha1 = name.endsWith(sha1Postfix);
    auto tailBase = wantSha1 ? tail[0 .. $ - sha1Postfix.length] : tail;

    auto dirPath = repositoryPathOf(ruri[0 .. dir.length]);
    if (!exists(dirPath) || !isDir(dirPath))
      return null;
    string best;
    SnapshotFile bestParsed;
    foreach (entry; dirEntries(dirPath, SpanMode.shallow)) {
      if (entry.isDir)
        continue;
      auto candidate = baseName(entry.name);
      // `.sha1` 只作为请求后缀出现；磁盘上的校验文件要剥掉后缀再按工件名解析。
      auto stampName = candidate;
      if (wantSha1) {
        if (!stampName.endsWith(sha1Postfix))
          continue;
        stampName = stampName[0 .. $ - sha1Postfix.length];
      } else if (stampName.endsWith(sha1Postfix)) {
        continue;
      }
      if (!stampName.startsWith(stampPrefix))
        continue;
      SnapshotFile parsed;
      if (!parseSnapshotName(stampName, artifact, ver, parsed))
        continue;
      auto want = (parsed.classifier.length > 0 ? "-" ~ parsed.classifier : "") ~ "." ~ parsed.ext;
      if (tailBase != want)
        continue;
      if (best.length == 0 || compareSnapshot(bestParsed, parsed) < 0) {
        best = candidate;
        bestParsed = parsed;
      }
    }
    return best.length > 0 ? dir ~ "/" ~ best : null;
  }

  /// 相对 uri → 仓库内绝对路径（调用方须保证 uri 已由 `micdn.web` 消解，无 `.`/`..`）。
  string repositoryPathOf(string ruri) const {
    return base ~ ruri;
  }
}

/** 从工件内部读坐标。

    顺序：`META-INF/maven/{group}/{artifact}/pom.properties`（war 在 `WEB-INF/classes/` 下）
    → `META-INF/MANIFEST.MF` 的
    `Implementation-Vendor-Id` / `Implementation-Title` / `Implementation-Version`（与 sashub 同口径）。
    `.pom` 直接解析 XML（groupId / 版本号可继承自 `<parent>`）。
*/
SnapshotCoordinates readSnapshotCoordinates(string artifactFile) {
  import std.exception : enforce;

  enforce(exists(artifactFile) && !isDir(artifactFile), "snapshot artifact not found: " ~ artifactFile);
  auto coords = artifactFile.toLower.endsWith(".pom")
    ? readPomCoordinates(artifactFile) : readArchiveCoordinates(artifactFile);
  enforce(coords.group.length > 0 && coords.artifact.length > 0 && coords.ver.length > 0,
      "cannot read groupId/artifactId/version from " ~ artifactFile
      ~ " (need META-INF/maven/**/pom.properties, MANIFEST.MF Implementation-* or pom.xml)");
  return coords;
}

/** 把 `file` 装入 `repo` 的对应版本目录，写 sha1 并刷新 maven-metadata.xml。

    同名文件按覆盖处理（重复 install 同一构件是幂等的）；坐标与文件名不匹配时抛 Exception，
    消息面向使用者（CLI 直接打印）。版本非 `-SNAPSHOT`、或文件名不带时间戳（未经 `mvn deploy`）
    都拒绝——`/maven` 不接受裸 `-SNAPSHOT.jar`。
*/
SnapshotResult installSnapshot(SnapshotRepo repo, string file) {
  import std.exception : enforce;

  auto coords = readSnapshotCoordinates(file);
  enforce(coords.ver.endsWith("-SNAPSHOT"),
      "not a SNAPSHOT version (" ~ coords.ver ~ "); only -SNAPSHOT artifacts can be installed");

  auto fileName = baseName(file);
  SnapshotFile parsed;
  enforce(parseSnapshotName(fileName, coords.artifact, coords.ver, parsed), "snapshot file name must be "
      ~ coords.artifact ~ "-" ~ coords.ver[0 .. $ - "-SNAPSHOT".length] ~ "-{timestamp}-{build}[-classifier].{ext}"
      ~ " as produced by `mvn deploy`, got " ~ fileName);

  auto dir = repo.versionDir(coords.group, coords.artifact, coords.ver);
  mkdirRecurse(dir);
  auto dest = dir ~ "/" ~ fileName;
  copy(file, dest);
  writeSha1(dest);
  auto metadata = writeSnapshotMetadata(repo, coords);
  return SnapshotResult(coords, fileName, dest, metadata,
      repo.uriOf(coords.group, coords.artifact, coords.ver, fileName));
}

/** 扫描版本目录重写 `maven-metadata.xml`（+ `.sha1`）。

    `<snapshot>` / `<lastUpdated>` 取最新构建的 (timestamp, build)；`<snapshotVersions>` 只列**最新构建**
    的文件（ext 与 classifier 各一条，`<value>` 为该构建的 `{version-without-SNAPSHOT}-{timestamp}-{build}`）——
    与真实仓库一致：旧构建的文件仍留在磁盘上、按带时间戳的完整路径可直接取，只是不出现在元数据里，
    客户端因此只会解析到最新构建。

    每次 install 都整体重写（元数据由目录内容推导，无增量状态），`.sha1` 随之刷新。
*/
string writeSnapshotMetadata(SnapshotRepo repo, SnapshotCoordinates coords) {
  auto dir = repo.versionDir(coords.group, coords.artifact, coords.ver);
  mkdirRecurse(dir);

  string[] kinds;      // 形如 "jar" / "sources:jar"
  SnapshotFile newest;
  bool hasNewest;
  foreach (entry; dirEntries(dir, SpanMode.shallow)) {
    if (entry.isDir)
      continue;
    SnapshotFile parsed;
    if (!parseSnapshotName(baseName(entry.name), coords.artifact, coords.ver, parsed))
      continue;
    if (!hasNewest || compareSnapshot(newest, parsed) < 0) {
      newest = parsed;
      hasNewest = true;
    }
  }
  if (hasNewest) {
    foreach (entry; dirEntries(dir, SpanMode.shallow)) {
      if (entry.isDir)
        continue;
      SnapshotFile parsed;
      if (!parseSnapshotName(baseName(entry.name), coords.artifact, coords.ver, parsed)
          || compareSnapshot(newest, parsed) != 0)
        continue;
      auto kind = parsed.classifier.length > 0 ? parsed.classifier ~ ":" ~ parsed.ext : parsed.ext;
      if (!kinds.canFind(kind))
        kinds ~= kind;
    }
  }
  kinds.sort;

  auto app = appender!string;
  app.put("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
  app.put("<metadata modelVersion=\"1.1.0\">\n");
  app.put("  <groupId>" ~ coords.group ~ "</groupId>\n");
  app.put("  <artifactId>" ~ coords.artifact ~ "</artifactId>\n");
  app.put("  <version>" ~ coords.ver ~ "</version>\n");
  app.put("  <versioning>\n");
  if (hasNewest) {
    auto value = coords.ver[0 .. $ - "-SNAPSHOT".length] ~ "-" ~ newest.timestamp
      ~ "-" ~ newest.build.to!string;
    app.put("    <snapshot>\n");
    app.put("      <timestamp>" ~ newest.timestamp ~ "</timestamp>\n");
    app.put("      <buildNumber>" ~ newest.build.to!string ~ "</buildNumber>\n");
    app.put("    </snapshot>\n");
    app.put("    <lastUpdated>" ~ newest.timestamp.replace(".", "") ~ "</lastUpdated>\n");
    app.put("    <snapshotVersions>\n");
    foreach (kind; kinds) {
      auto parts = kind.split(":");
      app.put("      <snapshotVersion>\n");
      if (parts.length > 1)
        app.put("        <classifier>" ~ parts[0] ~ "</classifier>\n");
      app.put("        <extension>" ~ parts[$ - 1] ~ "</extension>\n");
      app.put("        <value>" ~ value ~ "</value>\n");
      app.put("        <updated>" ~ newest.timestamp.replace(".", "") ~ "</updated>\n");
      app.put("      </snapshotVersion>\n");
    }
    app.put("    </snapshotVersions>\n");
  }
  app.put("  </versioning>\n");
  app.put("</metadata>\n");

  auto metadata = dir ~ "/" ~ metadataFileName;
  std.file.write(metadata, app.data);
  writeSha1(metadata);
  return metadata;
}

/** 解析带时间戳的快照文件名，写入 `parsed` 并返回 true；不匹配返回 false。

    形如 `{artifact}-{ver-without-SNAPSHOT}-{yyyyMMdd.HHmmss}-{build}[-{classifier}].{ext}`：
    `ext` 必须全为字母（maven 约定的 jar/war/pom 等），`build` 必须为纯数字，时间戳必须形如
    `yyyyMMdd.HHmmss`（15 位、第 9 位是 `.`）。因此 `.sha1` / `.md5` 这类校验文件不会通过——
    它们由调用方（别名解析、目录扫描）另行剥掉后缀处理。
*/
bool parseSnapshotName(string fileName, string artifact, string ver, out SnapshotFile parsed) {
  // 落盘文件名用时间戳替换了 `-SNAPSHOT`：`{artifact}-{version-without-SNAPSHOT}-{timestamp}-{build}…`。
  auto stampVer = ver.endsWith("-SNAPSHOT") ? ver[0 .. $ - "-SNAPSHOT".length] : ver;
  auto prefix = artifact ~ "-" ~ stampVer ~ "-";
  if (!fileName.startsWith(prefix))
    return false;
  auto rest = fileName[prefix.length .. $];
  auto dot = rest.lastIndexOf('.');
  if (dot <= 0)
    return false;
  auto stem = rest[0 .. dot];
  auto ext = rest[dot + 1 .. $];
  if (ext.length == 0 || !ext.all!(c => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')))
    return false;
  auto firstDash = stem.indexOf('-');
  if (firstDash < 0)
    return false;
  auto timestamp = stem[0 .. firstDash];
  auto tail = stem[firstDash + 1 .. $];
  auto secondDash = tail.indexOf('-');
  auto buildText = secondDash < 0 ? tail : tail[0 .. secondDash];
  auto classifier = secondDash < 0 ? "" : tail[secondDash + 1 .. $];
  if (!isSnapshotTimestamp(timestamp) || buildText.length == 0 || !buildText.all!isDigit)
    return false;
  parsed = SnapshotFile(timestamp, buildText.to!int, classifier, ext);
  return true;
}

/// `yyyyMMdd.HHmmss`（如 `20250803.132600`）。
private bool isSnapshotTimestamp(string value) {
  if (value.length != 15 || value[8] != '.')
    return false;
  foreach (i, c; value) {
    if (i == 8)
      continue;
    if (c < '0' || c > '9')
      return false;
  }
  return true;
}

/// 比较两个快照构建：先时间戳后 build 号（时间戳格式定长，可直接字典序比较）。
private int compareSnapshot(const SnapshotFile a, const SnapshotFile b) {
  auto ts = cmp(a.timestamp, b.timestamp);
  return ts != 0 ? ts : (a.build < b.build ? -1 : (a.build > b.build ? 1 : 0));
}

/// 写 `{file}.sha1`（hex，小写，无换行）。
private void writeSha1(string file) {
  import std.file : read;

  std.file.write(file ~ sha1Postfix, toHexString(sha1Of(read(file))).toLower);
}

/// 从 jar/war 读坐标：先 `pom.properties`，再 `MANIFEST.MF`。
private SnapshotCoordinates readArchiveCoordinates(string file) {
  auto data = cast(ubyte[]) read(file);
  ZipArchive zip;
  try {
    zip = new ZipArchive(data);
  } catch (Exception e) {
    throw new Exception("not a readable jar/war: " ~ file ~ " (" ~ e.msg ~ ")");
  }
  foreach (name, member; zip.directory) {
    if (name.endsWith("/pom.properties")
        && (name.startsWith("META-INF/maven/") || name.startsWith("WEB-INF/classes/META-INF/maven/"))) {
      zip.expand(member);
      auto coords = coordinatesFromProperties(cast(string) member.expandedData);
      if (coords.group.length > 0 && coords.ver.length > 0)
        return coords;
    }
  }
  foreach (name, member; zip.directory) {
    if (name == "META-INF/MANIFEST.MF") {
      zip.expand(member);
      auto coords = coordinatesFromManifest(cast(string) member.expandedData);
      if (coords.group.length > 0 && coords.ver.length > 0)
        return coords;
    }
  }
  return SnapshotCoordinates.init;
}

/// 解析 `pom.properties`（groupId/artifactId/ver 三行）。
private SnapshotCoordinates coordinatesFromProperties(string content) {
  SnapshotCoordinates coords;
  foreach (line; content.splitLines) {
    auto text = line.strip;
    if (text.length == 0 || text[0] == '#' || text[0] == '!')
      continue;
    auto eq = text.indexOf('=');
    if (eq <= 0)
      continue;
    auto key = text[0 .. eq].strip;
    auto value = text[eq + 1 .. $].strip;
    if (key == "groupId")
      coords.group = value;
    else if (key == "artifactId")
      coords.artifact = value;
    else if (key == "version")
      coords.ver = value;
  }
  return coords;
}

/// 解析 MANIFEST.MF 主节（支持以空格开头的续行），取 sashub 用的三个 Implementation-* 属性。
private SnapshotCoordinates coordinatesFromManifest(string content) {
  SnapshotCoordinates coords;
  string lastKey;
  foreach (line; content.splitLines) {
    if (line.length == 0)
      break; // 主节结束
    if (line[0] == ' ') {
      if (lastKey.length == 0)
        continue;
      auto value = line[1 .. $].strip;
      if (lastKey == "Implementation-Vendor-Id")
        coords.group ~= value;
      else if (lastKey == "Implementation-Title")
        coords.artifact ~= value;
      else if (lastKey == "Implementation-Version")
        coords.ver ~= value;
      continue;
    }
    auto colon = line.indexOf(':');
    if (colon <= 0) {
      lastKey = "";
      continue;
    }
    lastKey = line[0 .. colon].strip;
    auto value = line[colon + 1 .. $].strip;
    if (lastKey == "Implementation-Vendor-Id")
      coords.group = value;
    else if (lastKey == "Implementation-Title")
      coords.artifact = value;
    else if (lastKey == "Implementation-Version")
      coords.ver = value;
    else
      lastKey = "";
  }
  return coords;
}

/// 解析 pom.xml：根元素取 groupId/artifactId/ver，缺 groupId/ver 时退回 `<parent>`。
private SnapshotCoordinates readPomCoordinates(string file) {
  import std.exception : enforce;

  DOMEntity!string root;
  try {
    root = parseDomRoot(cast(string) read(file), file);
  } catch (Exception e) {
    throw new Exception("cannot parse pom: " ~ file ~ " (" ~ e.msg ~ ")");
  }
  SnapshotCoordinates coords;
  foreach (node; children(root, "groupId"))
    coords.group = elementText(node);
  foreach (node; children(root, "artifactId"))
    coords.artifact = elementText(node);
  foreach (node; children(root, "version"))
    coords.ver = elementText(node);
  if (coords.group.length == 0 || coords.ver.length == 0) {
    auto parents = children(root, "parent");
    if (!parents.empty) {
      auto parent = parents.front;
      if (coords.group.length == 0)
        foreach (node; children(parent, "groupId"))
          coords.group = elementText(node);
      if (coords.ver.length == 0)
        foreach (node; children(parent, "version"))
          coords.ver = elementText(node);
    }
  }
  enforce(coords.artifact.length > 0, "pom lacks artifactId: " ~ file);
  return coords;
}

/// 元素下的直接文本（pom 里取值用）。
private string elementText(T)(ref DOMEntity!T dom) {
  auto app = appender!string;
  foreach (c; dom.children) {
    if (c.type == EntityType.text)
      app.put(c.text);
  }
  return app.data.strip;
}
