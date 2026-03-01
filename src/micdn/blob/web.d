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

import std.conv;
import std.datetime.systime;
import std.exception;
import std.file;
import std.stdio;
import std.string;

import vibe.core.core;
import vibe.core.file;
import vibe.core.log;
import vibe.http.auth.basic_auth;
import vibe.http.router;
import vibe.http.server;
import vibe.web.web;

import micdn.blob.store;
import micdn.model;
import micdn.web;
import micdn.web.file;
import micdn.fs.browser;
import micdn.web.server;
import micdn.xml;

class BlobService {
  private const string endpoint;
  private BlobRepo repo;

  this(MicdnConfig config, MetaDao metadao) {
    this.endpoint = config.blob.endpoint;
    this.repo = BlobRepo.build(config, metadao);
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
    auto rs = repo.check(uri);
    if (rs == 0) {
      throw new HTTPStatusException(HTTPStatus.notFound);
    } else if (rs == 1) { // dir
      throw new HTTPStatusException(HTTPStatus.notFound);
    } else { //file
      auto profile = repo.getProfile(uri);
      if (profile.publicDownload) {
        sendObject(repo, profile, req, res, uri);
      } else {
        auto token = ("token" in req.query);
        auto t = ("t" in req.query);
        auto user = ("u" in req.query);
        if (null == user || null == token || null == t) {
          if (basicAuth(req, res, profile)) {
            sendObject(repo, profile, req, res, uri);
          }
        } else if (checkToken(profile, uri, *user, profile.keys.get(*user, ""), *token, *t)) {
          sendObject(repo, profile, req, res, uri);
        } else {
          res.statusCode = HTTPStatus.forbidden;
          res.writeBody("bad token!", "text/plain");
        }
      }
    }
  }

  private void putObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    auto profile = repo.getProfile(uri);
    if (basicAuth(req, res, profile)) {
      auto pf = "file" in req.files;
      enforce(pf !is null, "No file uploaded!");
      import vibe.core.path;

      try {
        string owner = req.form.get("owner", "--");
        import vibe.inet.mimetypes;

        auto mediaType = getMimeTypeForFile(pf.toString);
        auto meta = repo.create(profile, pf.tempPath.toNativeString,
            pf.toString, uri, owner, mediaType);
        logInfo(
            "upload " ~ profile.base ~ meta.filePath ~ " at "
            ~ meta.updatedAt.toISOExtString ~ "(" ~ meta.owner ~ ")");
        res.writeBody(meta.toJson(), "application/json");
      } catch (Exception e) {
        logInfo("Performing copy failed.Cause %s", e.msg);
        res.statusCode = HTTPStatus.internalServerError;
        res.writeBody(e.msg, "text/plain");
      }
    }
  }

  private void deleteObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    auto profile = repo.getProfile(uri);
    if (basicAuth(req, res, profile)) {
      try {
        if (repo.remove(profile, uri)) {
          logInfo("remove " ~ uri ~ " at " ~ Clock.currTime().toISOExtString);
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

  bool checkToken(const(BlobProfile) profile, string uri, string user, string key,
      string token, string timestamp) {
    try {
      return profile.verifyToken(uri, user, key, token, SysTime.fromISOString(timestamp));
    } catch (Exception e) {
      return false;
    }
  }

  bool basicAuth(HTTPServerRequest req, HTTPServerResponse res, const(BlobProfile) profile) {
    bool checkPassword(string user, string password) @safe {
      return !user.empty && !password.empty && profile.keys.get(user, "") == password;
    }

    import std.functional : toDelegate;

    if (!checkBasicAuth(req, toDelegate(&checkPassword))) {
      res.statusCode = HTTPStatus.unauthorized;
      res.contentType = "text/plain";
      res.headers["WWW-Authenticate"] = `Basic realm="micdn"`;
      res.bodyWriter.write("Authorization required");
      return false;
    } else {
      return true;
    }
  }

}

//fixme for realname detection
void sendObject(BlobRepo repo, const(BlobProfile) profile, HTTPServerRequest req,
    HTTPServerResponse res, string path) {
  import std.path;

  auto ext = extension(path);
  if (ext in repo.images) {
    sendFile(req, res, repo.base ~ path, null);
  } else {
    auto realname = repo.getRealname(profile, path[profile.base.length .. $]);
    if (realname.length > 0) {
      void setContextDisposition(scope HTTPServerRequest req,
          scope HTTPServerResponse res, ref string physicalPath) @safe {
        res.headers["Content-Disposition"] = encodeAttachmentName(realname);
      }

      auto settings = new CacheSetting;
      settings.preWrite = &setContextDisposition;
      sendFile(req, res, repo.base ~ path, settings);
    } else {
      sendFile(req, res, repo.base ~ path, null);
    }
  }
}
