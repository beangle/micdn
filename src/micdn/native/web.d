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

module micdn.native.web;
/** native 发行包仓库的 HTTP 服务：GET/HEAD 读取（含目录列表）与令牌授权的 PUT 上传。

    承接 sashub 的 `/repo/native`：上传 `PUT /native/{仓库内相对路径}`（**全路径 URL**，
    不用 query string 传 path），令牌同 `<auth publish-key="…"/>`；下载 `GET|HEAD /native/{相对路径}`。
    native 没有元数据文件，坐标与文件名都由客户端决定，因此落盘路径就是请求路径，
    micdn 只做原子写入与别名解析（见 `micdn.native.NativeRepo`）。
*/

import std.exception;
import std.file : exists, timeLastModified;
import std.path;
import std.string;

import vibe.core.file;
import vibe.core.log;
import vibe.http.common : HTTPMethod, HTTPStatus;
import vibe.http.router;
import vibe.http.server;
import vibe.inet.message : toRFC822DateTimeString;

import micdn.fs.browser;
import micdn.fs.index;
import micdn.model;
import micdn.native;
import micdn.routes;
import micdn.web;
import micdn.web.cache;
import micdn.web.file;
import micdn.web.publish : authorizeRead, authorizeWrite, readNeedsToken, readUploadBody, storeUpload;

class NativeService {
  private enum string endpoint = mountNative;
  private const NativeRepo repo;
  /** 上传令牌（`<auth publish-key="…"/>`）；空表示未启用发布，PUT 一律 401。 */
  private string publishKey;
  /** 下载令牌（`<auth download-key="…"/>`）；空表示读不认证。 */
  private string downloadKey;
  /** 上传体上限（来自 `<auth max-size>`）——native 发行包是几十 MB 量级，需按需调大。 */
  private size_t publishMaxSize;

  this(MicdnConfig config) {
    this.repo = NativeRepo.build(config);
    if (config.auth !is null) {
      this.publishKey = config.auth.publishKey;
      this.downloadKey = config.auth.downloadKey;
      this.publishMaxSize = config.auth.maxSize;
    }
  }

  /** 单个 `/native` 入口：

      1. 不带时间戳的补丁别名（`{a}-{基准版本}_{版本}-{classifier}.tar.gz.diff[.sha1]`）重定向到同目录
         最新的时间戳文件，`HEAD` 以 `latest` 头回带实际文件名、并给出 `Last-Modified`
         （jstart 用 `curl -I -L` 探测补丁是否存在，要求最终 200）；
      2. 本地已有则直接发文件；
      3. 目录（含仓库根）缺尾斜杠先 302 补 `/`，再列目录；文件缺失 404。

      没有上游回源：native 仓库不在 micdn 缓存上游镜像，迁移期未同步到的构件就是 404。
  */
  void service(HTTPServerRequest req, HTTPServerResponse res) {
    if (req.method == HTTPMethod.PUT) {
      // 写路径的唯一入口：先校验令牌，再做任何路径解析与 body 读取
      if (!authorizeWrite(req, res, publishKey))
        return;
      publish(req, res);
      return;
    }
    const uri = getResourceUri(endpoint, req);
    const ruri = repositoryUri(uri);
    // `<auth download-key>`：受保护的 GET 先鉴权（HEAD/目录/302 放行，见 micdn.web.publish）
    if (!authorizeRead(req, res, downloadKey, ruri))
      return;
    const gated = readNeedsToken(req, downloadKey, ruri);

    auto latest = repo.latestAlias(ruri);
    if (latest !is null) {
      res.headers["latest"] = baseName(latest);
      auto latestPath = repo.fileOf(latest);
      if (exists(latestPath))
        // HTTP-date 必须是 GMT（与 `/maven` 的快照别名同口径）
        res.headers["Last-Modified"] = toRFC822DateTimeString(timeLastModified(latestPath).toUTC());
      if (req.method == HTTPMethod.HEAD) {
        res.statusCode = HTTPStatus.ok;
        res.writeVoidBody();
        return;
      }
      res.redirect(endpoint ~ latest);
      return;
    }

    auto file = repo.fileOf(ruri);
    FileInfo fi;
    try
      fi = getFileInfo(file);
    catch (Exception)
      throw new HTTPStatusException(HTTPStatus.notFound);

    if (fi.isDirectory) {
      if (req.method == HTTPMethod.HEAD)
        throw new HTTPStatusException(HTTPStatus.methodNotAllowed);
      if (uri.slashEnded) {
        auto listData = genListContents(file, endpoint, ruri);
        render!("index.dt", listData)(res);
      } else {
        res.redirect(directoryUri(endpoint, uri));
      }
    } else {
      auto info = IndexedFileInfo.fromFileInfo(fi);
      auto policy = nativeArtifactCachePolicy(ruri);
      sendFile(req, res, file, info, gated ? gatedPolicy(policy) : policy);
    }
  }

  /** 上传：把请求体原子写入请求路径对应的位置（覆盖同名文件）。

      客户端须**先传构件、再传 `.sha1`**：micdn 只做原子落盘，不实现 sashub 的
      `.pending` 暂存与「校验文件先到时归位」。
      调用方（`service` 的 PUT 分支）已通过 `authorizeWrite` 校验令牌。
  */
  private void publish(HTTPServerRequest req, HTTPServerResponse res) {
    const uri = getResourceUri(endpoint, req);
    const ruri = repositoryUri(uri);
    auto body = readUploadBody(req.bodyReader, publishMaxSize);
    try
      storeUpload(repo.base, ruri, body);
    catch (HTTPStatusException e)
      throw e;
    catch (Exception e)
      throw new HTTPStatusException(HTTPStatus.badRequest, e.msg);
    logInfo("native publish: %s (%d bytes)", ruri, body.length);
    res.statusCode = HTTPStatus.created;
    res.writeVoidBody();
  }
}
