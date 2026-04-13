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

module micdn.blob.web;
/// Blob HTTP 服务入口，提供上传、下载与元数据操作接口。

import core.time : dur;

import std.conv : to;
import std.datetime.systime;
import std.datetime.timezone : UTC;
import std.digest : toHexString, LetterCase;
import std.digest.sha : sha1Of;
import std.exception;
import std.path : dirName;
import std.string;

import vibe.core.core;
import vibe.core.file;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.web.web;

import micdn.blob.store;
import micdn.model;
import micdn.routes;
import micdn.web;
import micdn.web.cache;
import micdn.web.file;

class BlobService {
  private enum string endpoint = mountBlob;
  private BlobRepo repo;

  this(BlobRepo repo) {
    this.repo = repo;
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto uri = getPath(this.endpoint, req);
    switch (req.method) {
    case HTTPMethod.GET:
      getObject(req, res, uri);
      break;
    case HTTPMethod.POST:
      putObject(req, res, uri);
      break;
    case HTTPMethod.DELETE:
      deleteObject(req, res, uri);
      break;
    default:
      res.statusCode = HTTPStatus.methodNotAllowed;
      res.writeBody("Method not allowed", "text/plain");
    }
  }

  private void getObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    auto br = repo.resolveBlob(uri);
    if (br.bucket.name.length == 0) {
      throw new HTTPStatusException(HTTPStatus.notFound);
    }

    auto rs = repo.check(br.bucket, br.objectPath);
    if (rs == 0) {
      throw new HTTPStatusException(HTTPStatus.notFound);
    } else if (rs == 1) { // dir
      throw new HTTPStatusException(HTTPStatus.notFound);
    } else { // file：Bearer 或 ?token=&t=（SHA1(uri+key+t)，t 起 5 分钟内有效）
      if (downloadAuthorized(br.bucket, req, uri)) {
        sendObject(repo, br.bucket, br.objectPath, req, res);
      } else {
        res.statusCode = HTTPStatus.unauthorized;
        res.headers["WWW-Authenticate"] = `Bearer realm="micdn"`;
        res.writeBody("Authorization required (Bearer or ?token=&t=)", "text/plain");
      }
    }
  }

  private void putObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    auto br = repo.resolveBlob(uri);
    if (!bearerMatches(br.bucket, req)) {
      res.statusCode = HTTPStatus.unauthorized;
      res.headers["WWW-Authenticate"] = `Bearer realm="micdn"`;
      res.writeBody("Authorization required", "text/plain");
      return;
    }
    auto pf = "file" in req.files;
    enforce(pf !is null, "No file uploaded!");
    import vibe.core.path;

    try {
      string owner = req.form.get("owner", "--");
      // `create` 的 dir 为桶内逻辑路径；须用 `objectPath`（已去掉首段 bucket），不可传完整 uri，否则 toPhysicalPath 会重复 bucket 段。
      auto meta = repo.create(br.bucket, pf.tempPath.toNativeString, pf.toString, dirName(br.objectPath), owner);
      logInfo("Uploaded " ~ uri);
      res.writeBody(meta.toJson(), "application/json");
    } catch (Exception e) {
      logInfo("Performing copy failed.Cause %s", e.msg);
      res.statusCode = HTTPStatus.internalServerError;
      res.writeBody(e.msg, "text/plain");
    }
  }

  private void deleteObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    auto br = repo.resolveBlob(uri);
    if (!bearerMatches(br.bucket, req)) {
      res.statusCode = HTTPStatus.unauthorized;
      res.headers["WWW-Authenticate"] = `Bearer realm="micdn"`;
      res.writeBody("Authorization required", "text/plain");
      return;
    }
    try {
      if (repo.remove(br.bucket, br.objectPath)) {
        logInfo("Remove " ~ uri);
        res.writeBody("File removed!", "text/plain");
      } else {
        res.writeBody("File is not existed!", "text/plain");
      }
    } catch (Exception e) {
      logInfo("Performing remove failed.Cause %s", e.msg);
      res.statusCode = HTTPStatus.internalServerError;
      res.writeBody(e.msg, "text/plain");
    }
  }
}

/// `Authorization: Bearer <key>`，`key` 与 micdn.xml 中 bucket 的 `key` 一致。
bool bearerMatches(const Bucket bucket, HTTPServerRequest req) {
  if (bucket.name.length == 0 || bucket.key.length == 0)
    return false;
  auto auth = req.headers.get("Authorization", "");
  if (!auth.startsWith("Bearer "))
    return false;
  import std.string : strip;

  return strip(auth[7 .. $]) == bucket.key;
}

/// 解析 `t`（yyyyMMdd'T'HHmmss，UTC）。
private SysTime parseBlobTokenTime(string t) {
  import std.datetime.date : DateTime;
  import std.string : strip;

  t = strip(t);
  enforce(t.length == 15 && t[8] == 'T', "invalid t");
  int y = t[0 .. 4].to!int;
  int mo = t[4 .. 6].to!int;
  int d = t[6 .. 8].to!int;
  int H = t[9 .. 11].to!int;
  int mi = t[11 .. 13].to!int;
  int sec = t[13 .. 15].to!int;
  return SysTime(DateTime(y, mo, d, H, mi, sec), UTC());
}

/// `?token=hex&t=...`：token = sha1hex(uri + key + t)，且当前 UTC 时间在 [t, t+5min]。
bool signedQueryTokenMatches(const Bucket bucket, string uri, HTTPServerRequest req) {
  if (bucket.name.length == 0 || bucket.key.length == 0)
    return false;
  import std.string : strip;

  string tok = strip(req.query.get("token", ""));
  string ts = strip(req.query.get("t", ""));
  if (tok.length == 0 || ts.length == 0)
    return false;

  string expected = toHexString!(LetterCase.lower)(sha1Of(uri ~ bucket.key ~ ts)).idup;
  if (tok != expected)
    return false;
  try {
    SysTime t0 = parseBlobTokenTime(ts);
    SysTime now = Clock.currTime(UTC());

    if (now < t0)
      return false;
    if (now > t0 + dur!"minutes"(5))
      return false;
    return true;
  } catch (Exception e) {
    return false;
  }
}

/// GET 下载：Bearer，或带签名的 `?token=&t=`。
bool downloadAuthorized(const Bucket bucket, HTTPServerRequest req, string uri) {
  return bearerMatches(bucket, req) || signedQueryTokenMatches(bucket, uri, req);
}

/// GET 下载响应体；缓存策略见 `blobObjectCachePolicy`。
void sendObject(BlobRepo repo, const Bucket bucket, string objectPath,
    HTTPServerRequest req, HTTPServerResponse res) {
  import std.path;

  auto physicalPath = repo.toPhysicalPath(bucket, objectPath);
  auto ext = extension(objectPath);
  if (ext in repo.images) {
    sendFile(req, res, physicalPath, blobObjectCachePolicy());
  } else {
    auto realname = repo.getRealname(bucket, objectPath);
    if (realname.length > 0) {
      void setContextDisposition(scope HTTPServerRequest req, scope HTTPServerResponse res) @safe {
        res.headers["Content-Disposition"] = encodeAttachmentName(realname);
      }
      sendFile(req, res, physicalPath, blobObjectCachePolicy(), &setContextDisposition);
    } else {
      sendFile(req, res, physicalPath, blobObjectCachePolicy());
    }
  }
}
