/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.npm.web;
/// NPM 仓库 HTTP 服务：版本化 tarball 与 packument 元数据（本地文件，缺失时按同一路径从上游拉取）。

import std.algorithm;
import std.exception;
import std.file;
import std.string;

import vibe.core.core;
import vibe.core.file;
import vibe.http.fileserver : handleCacheFile;
import vibe.http.router;
import vibe.http.server;

import micdn.fs.browser;
import micdn.model;
import micdn.routes;
import micdn.npm;
import micdn.npm.packument : originPlaceholder;
import micdn.web;
import micdn.web.cache;
import micdn.web.file;
import micdn.web.origin;
import micdn.fs.index;

class NpmService {
  private enum string endpoint = mountNpm;
  private const NpmRepo repo;

  this(MicdnConfig config) {
    this.repo = NpmRepo.build(config);
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    const uri = getResourceUri(endpoint, req);
    const ruri = repositoryUri(uri);
    auto path = repositoryPath(repo.base, uri);

    // 支持 NPM 官方 tgz URL：{packageName}/-/{name}-{version}.tgz，不存在则下载后返回
    if (ruri.canFind("/-/") && ruri.endsWith(".tgz")) {
      auto parsed = parseTarballUri(ruri);
      if (parsed[0]!is null && parsed[1]!is null && parsed[2]!is null) {
        if (repo.fetch(parsed[0], parsed[1], parsed[2])) {
          auto local = repo.localTarball(parsed[0], parsed[1], parsed[2]);
          FileInfo tfi;
          try
            tfi = getFileInfo(local);
          catch (Exception)
            throw new HTTPStatusException(HTTPStatus.notFound);
          auto info = IndexedFileInfo.fromFileInfo(tfi);
          sendFile(req, res, local, info, npmArtifactCachePolicy(ruri));
          return;
        }
        throw new HTTPStatusException(HTTPStatus.notFound);
      }
    }

    FileInfo fi;
    try {
      fi = getFileInfo(path);
    } catch (Exception) {
      // 本地缺失：包元数据（packument）按同一路径从上游拉取后发送；其余（含 tgz 未命中缓存）直接 404。
      if (!repo.fetchPackument(ruri))
        throw new HTTPStatusException(HTTPStatus.notFound);
      try
        fi = getFileInfo(path);
      catch (Exception)
        throw new HTTPStatusException(HTTPStatus.notFound);
    }

    if (fi.isDirectory) {
      if (req.method == HTTPMethod.HEAD) {
        throw new HTTPStatusException(HTTPStatus.methodNotAllowed);
      }
      if (ruri.endsWith("/")) {
        applyCachePolicy(res, npmArtifactCachePolicy(ruri));
        auto listData = genListContents(path, endpoint, ruri);
        render!("index.dt", listData)(res);
      } else {
        auto pub = endpoint ~ ruri;
        res.redirect(req.requestURI.replace(pub, pub ~ "/"));
      }
    } else {
      // 包名路径按 registry 约定是 packument（JSON），交付时把 `{origin}` 换成实际 origin；
      // 其余（缓存目录下的 tgz 等）按文件发送。
      if (isPackageUri(ruri))
        sendPackument(req, res, path, fi, ruri);
      else {
        auto info = IndexedFileInfo.fromFileInfo(fi);
        sendFile(req, res, path, info, npmArtifactCachePolicy(ruri));
      }
    }
  }

  /** 交付 packument：把 `{origin}` 占位符换成请求 origin（`micdn.web.origin.getOrigin`）后写出。

      上游代理来的 packument 是绝对地址、不含占位符，替换为空操作，原样发送。
      缓存头与 304 条件响应经 `handleCacheFile` 处理，与 `sendFile` 同口径（ETag/Last-Modified）。
      条件请求命中 304 时直接返回，不读盘、不替换。包名路径无扩展名，Content-Type 自行标注为 JSON；
      Content-Length 由 vibe 按替换后的正文写入（HEAD 因此拿到替换后的长度、无正文）。

      注意 ETag 取的是**文件**的 size/mtime，与替换结果无关：中间共享缓存若按 URL 分键（常规做法，
      不同域名即不同 URL）不会串；若确需同一 URL 对多域名给出各自正文，应让反代按 Host 分键，
      或把本路径的缓存策略改成 `private`/`no-store`。
  */
  private void sendPackument(scope HTTPServerRequest req, scope HTTPServerResponse res,
      string path, FileInfo fi, string ruri) {
    auto policy = npmArtifactCachePolicy(ruri);
    if (handleCacheFile(req, res, fi, policy.cacheControl, policy.maxAge))
      return;

    auto origin = getOrigin(req);
    auto content = cast(string) read(path);
    if (origin.length > 0 && content.canFind(originPlaceholder))
      content = content.replace(originPlaceholder, origin);
    res.headers["Content-Type"] = "application/json; charset=utf-8";
    res.writeBody(content);
  }
}
