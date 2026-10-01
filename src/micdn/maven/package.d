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

module micdn.maven;
/// Maven 代理服务配置解析与远程仓库列表管理。
///
/// 正式版与 SNAPSHOT **共用** `/maven` 入口与 `<maven base>` 目录树（按版本目录名区分），回源时按路径选上游。
/// 整体设计（含元数据合并与缓存策略）见 `docs/merged_repo.md`。

import std.algorithm;
import std.conv;
import std.datetime : Clock, Duration, dur;
import std.exception;
import std.file;
import std.path : baseName, dirName;
import std.stdio;
import std.string;

import std.digest.sha;

import dxml.dom;

import vibe.core.log;

import micdn.model;
import micdn.web.file;
import micdn.web : normalizeBasePath;
import micdn.xml;

/** Maven 仓库根：本地缓存与上游回源（正式版 `remotes` / 快照 `snapshotRemote`）。

    正式版与快照**共用**同一 `base`，按请求路径选上游（`isSnapshotUri` / `upstreamsFor`）。入口 `/maven`
    见 `micdn.maven.web.MavenService`；整体设计见 `docs/merged_repo.md`。
*/
class GavRepo {
  /** artifact 本地仓库根目录（绝对路径） */
  const string base;
  /** 正式版上游仓库 URL 列表（按优先级） */
  const string[] remotes = [];
  /** SNAPSHOT 专用上游；空串表示不代理 SNAPSHOT（只发本地已装入的构件） */
  const string snapshotRemote = "";
  /** SNAPSHOT 版本目录 maven-metadata.xml 的缓存有效期（见 `refreshSnapshotMetadata`）。 */
  Duration snapshotMetadataTtl = dur!"seconds"(60);

  static Sha1Postfix = ".sha1";

  this(const(string) base, const(string[]) remotes, const(string) snapshotRemote = "") {
    enforce(base.length > 0, "repo base must not be empty");
    this.base = normalizeBasePath(base);
    this.remotes = remotes;
    this.snapshotRemote = snapshotRemote;
  }

  static GavRepo build(MicdnConfig config) {
    mkdirRecurse(config.maven.base);
    return new GavRepo(config.maven.base, config.maven.remotes, config.maven.snapshotRemote);
  }

  /** 相对 uri 是否为 SNAPSHOT 路径：存在以 `-SNAPSHOT` 结尾的路径段。

      版本目录（`.../1.0.0-SNAPSHOT/...`）与同目录下不带时间戳的别名文件名
      （`tool-1.0.0-SNAPSHOT.jar`）都满足；只认「段以 `-SNAPSHOT` 结尾」而不是全文包含
      `SNAPSHOT`，artifactId 里含 `SNAPSHOT` 的正式版构件（如 `SNAPSHOTter-1.0.jar`）
      因而不会被误判成 SNAPSHOT、走错上游。
  */
  static bool isSnapshotUri(string uri) {
    foreach (seg; uri.split("/"))
      if (seg.endsWith("-SNAPSHOT") && seg.length > "-SNAPSHOT".length)
        return true;
    return false;
  }

  /** 该 uri 适用的上游列表：SNAPSHOT 只走 `<snapshot remote=...>`（未配置则空 = 不代理，
      不回退正式版 `remotes`）；其余走 `remotes`。与 npm 侧 `NpmRepo.upstreamsFor` 同口径。
  */
  const(string[]) upstreamsFor(string uri) const {
    if (isSnapshotUri(uri))
      return snapshotRemote.length > 0 ? [snapshotRemote] : [];
    return remotes;
  }

  /// `ruri` 所在 SNAPSHOT 版本目录的 maven-metadata.xml 相对 uri；不在 SNAPSHOT 版本目录下返回 null。
  static string snapshotMetadataUri(string ruri) {
    auto dir = dirName(ruri);
    return dir.endsWith("-SNAPSHOT") ? dir ~ "/maven-metadata.xml" : null;
  }

  /** 按 TTL 从 `<snapshot remote>` 刷新 SNAPSHOT 版本目录的元数据（best effort）。

      SNAPSHOT 的 maven-metadata.xml 描述「最新构建」，上游每次 deploy 都会变；只发本地副本会让
      客户端永远解析到第一次取回的那个构建。因此在交付 SNAPSHOT 元数据/别名前调用本方法：

      - 未配置 `<snapshot remote>`、或路径不在 SNAPSHOT 版本目录下：什么都不做，返回 false；
      - 本地副本还在 `snapshotMetadataTtl` 内：不动，返回 true；
      - 过期：重新下载并（若上游带 `.sha1`）校验；下载或校验失败**保留本地旧副本**——
        SNAPSHOT 宁可稍旧，也不能因为上游抖动而删掉可用缓存。

      返回「本地现在是否有可用的元数据」。
  */
  bool refreshSnapshotMetadata(string ruri) const {
    auto metaUri = snapshotMetadataUri(ruri);
    if (metaUri is null || snapshotRemote.length == 0)
      return false;
    auto local = this.base ~ metaUri;
    if (exists(local) && Clock.currTime() - timeLastModified(local) < snapshotMetadataTtl)
      return true;
    auto incoming = dirName(local) ~ "/." ~ baseName(local) ~ ".incoming";
    scope (exit)
      if (exists(incoming))
        std.file.remove(incoming);
    if (!curlDownload(snapshotRemote ~ metaUri, incoming)) {
      logWarn("SNAPSHOT metadata refresh failed for %s, keeping cached copy", metaUri);
      return exists(local);
    }
    auto incomingSha1 = incoming ~ Sha1Postfix;
    scope (exit)
      if (exists(incomingSha1))
        std.file.remove(incomingSha1);
    if (curlDownload(snapshotRemote ~ metaUri ~ Sha1Postfix, incomingSha1)) {
      auto actual = toHexString(sha1Of(cast(const(ubyte)[]) read(incoming))).idup.toLower;
      if (readText(incomingSha1).toLower.indexOf(actual) < 0) {
        logWarn("SNAPSHOT metadata sha1 mismatch for %s, keeping cached copy", metaUri);
        return exists(local);
      }
    }
    mkdirRecurse(dirName(local));
    rename(incoming, local);
    return true;
  }

  bool fetch(string uri) const {
    if (uri.endsWith(".sha1")) {
      return download(uri);
    } else {
      download(uri ~ ".sha1");
      download(uri);
      int res = verify(uri);
      if (res < 0) {
        remove(uri);
        return false;
      } else {
        return true;
      }
    }
  }

  /** remove artifact by relative uri
   * @param uri relative uri to base
   */
  void remove(string uri) const {
    auto sha1 = this.base ~ uri ~ Sha1Postfix;
    auto artifact = this.base ~ uri;
    if (exists(sha1)) {
      logInfo("Remove %s", sha1);
      std.file.remove(sha1);
    }
    if (exists(artifact)) {
      logInfo("Remove %s", artifact);
      std.file.remove(artifact);
    }
  }

  /** verify artifact
   * return 0 is ok. -1 miss match sha1,-2 missing artifact ,-3 missing sha1
   */
  int verify(string uri) const {
    auto sha1 = this.base ~ uri ~ Sha1Postfix;
    auto artifact = this.base ~ uri;

    if (!exists(sha1))
      return -1;
    if (!exists(artifact))
      return -2;

    logInfo("Verify %s against sha1", artifact);
    File file = File(artifact);
    auto digest = new SHA1Digest();
    foreach (buffer; file.byChunk(4096 * 1024))
      digest.put(buffer);
    ubyte[] result = digest.finish();
    auto hexCalc = toHexString(result).toLower;
    auto sha1InFile = readText(sha1).toLower;
    auto ok = sha1InFile.indexOf(hexCalc) >= 0;
    if (!ok) {
      logWarn("Miss match sha for %s. sha1file %s and calculated is %s",
          artifact, sha1InFile, hexCalc);
      return -1;
    } else {
      return 0;
    }
  }

  /** try to download file
   * @return true if local exists
  */
  private bool download(string uri) const {
    auto local = this.base ~ uri;
    if (exists(local)) {
      return true;
    }
    foreach (r; upstreamsFor(uri)) {
      auto remote = r ~ uri;
      if (curlDownload(remote, local)) {
        break;
      }
    }
    return exists(local);
  }

}
