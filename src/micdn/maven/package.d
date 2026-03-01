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

import std.algorithm;
import std.conv;
import std.file;
import std.path;
import std.stdio;
import std.string;

import std.digest.sha;

import dxml.dom;

import vibe.core.log;

import micdn.model;
import micdn.web.file;
import micdn.xml;

class GavRepo {
  /**artifact local repo*/
  const string base;
  /**candinates remote repos*/
  const string[] remotes = [];

  static Sha1Postfix = ".sha1";

  this(const(string) base, const(string[]) remotes) {
    this.base = base;
    this.remotes = remotes;
  }

  static GavRepo build(MicdnConfig config) {
    mkdirRecurse(config.maven.base);
    return new GavRepo(config.maven.base, config.maven.remotes);
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
    mkdirRecurse(dirName(local));
    foreach (r; this.remotes) {
      auto remote = r ~ uri;
      if (curlDownload(remote, local)) {
        logInfo("Downloaded %s", remote);
        break;
      }
    }
    return exists(local);
  }

}
