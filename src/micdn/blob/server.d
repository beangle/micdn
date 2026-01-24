module micdn.blob.server;

import std.stdio;
import std.file;
import std.string;
import std.exception;
import std.datetime.systime;
import std.conv;
import vibe.core.core;
import vibe.core.log;
import vibe.core.file;
import vibe.http.router;
import vibe.http.server;
import vibe.http.auth.basic_auth;
import vibe.web.web;
import micdn.blob.repository;
import micdn.blob.config;
import micdn.blob.db;
import micdn.blob.s3;
import micdn.web;
import micdn.web.server;
import micdn.web.file;
import micdn.web.filebrowser;
import micdn.xml.reader;

private class BlobServer {
  const string home;
  const ServerOptions options;
  const Config config;
  Repository repository;

  this(string home, ServerOptions options, Config config, Repository repository) {
    this.home = home;
    this.options = options;
    this.config = config;
    this.repository = repository;
  }
}

BlobServer server;

void blobStart(string home, ServerOptions options, string configFile) {
  auto config = Config.parse(home, readXml(configFile));
  MetaDao metaDao = null;
  if (!config.dataSourceProps.empty) {
    metaDao = new MetaDao(config.dataSourceProps, config);
  }
  auto repository = new Repository(config.base, metaDao);
  server = new BlobServer(home, options, config, repository);
  auto router = new URLRouter(options.contextPath);
  router.get("*", &index);
  router.post("*", &upload);
  router.delete_("*", &remove);

  // S3 protocol routes with /s3 prefix
  router.get("/s3/*", &s3Handle);
  router.put("/s3/*", &s3Handle);
  router.delete_("/s3/*", &s3Handle);
  router.match(HTTPMethod.HEAD, "/s3/*", &s3Handle);

  auto settings = new HTTPServerSettings;
  settings.maxRequestSize = config.maxSize;
  settings.bindAddresses = server.options.ips.dup;
  settings.port = server.options.port;
  settings.serverString = null;

  listenHTTP(settings, router);
}

void index(HTTPServerRequest req, HTTPServerResponse res) {
  auto uri = getPath(server.options.contextPath, req);
  auto rs = server.repository.check(uri);
  if (rs == 0) {
    throw new HTTPStatusException(HTTPStatus.notFound);
  } else if (rs == 1) { // dir
    if (server.config.publicList) {
      if (uri.endsWith("/")) {
        auto content = genListContents(server.repository.base ~ uri, server.options.contextPath, uri);
        render!("index.dt", uri, content)(res);
      } else {
        import std.array;

        uri = server.options.contextPath ~ uri;
        res.redirect(req.requestURI.replace(uri, uri ~ "/"));
      }
    } else {
      throw new HTTPStatusException(HTTPStatus.notFound);
    }
  } else { //file
    auto profile = server.config.getProfile(uri);
    if (profile.publicDownload) {
      download(profile, req, res, uri);
    } else {
      auto token = ("token" in req.query);
      auto t = ("t" in req.query);
      auto user = ("u" in req.query);
      if (null == user || null == token || null == t) {
        if (basicAuth(req, res, profile)) {
          download(profile, req, res, uri);
        }
      } else if (checkToken(profile, uri, *user, profile.keys.get(*user, ""), *token, *t)) {
        download(profile, req, res, uri);
      } else {
        res.statusCode = HTTPStatus.forbidden;
        res.writeBody("bad token!", "text/plain");
      }
    }
  }
}

void upload(HTTPServerRequest req, HTTPServerResponse res) {
  auto uri = getPath(server.options.contextPath, req);
  auto profile = server.config.getProfile(uri);
  if (basicAuth(req, res, profile)) {
    auto pf = "file" in req.files;
    enforce(pf !is null, "No file uploaded!");
    import vibe.core.path;

    try {
      string owner = req.form.get("owner", "--");
      import vibe.inet.mimetypes;

      auto mediaType = getMimeTypeForFile(pf.toString);
      auto meta = server.repository.create(profile, pf.tempPath.toNativeString, pf.toString, uri, owner, mediaType);
      logInfo("upload " ~ profile.base ~ meta.filePath ~ " at " ~ meta.updatedAt.toISOExtString ~ "(" ~ meta.owner ~ ")");
      res.writeBody(meta.toJson(), "application/json");
    } catch (Exception e) {
      logInfo("Performing copy failed.Cause %s", e.msg);
      res.statusCode = HTTPStatus.internalServerError;
      res.writeBody(e.msg, "text/plain");
    }
  }
}

void remove(HTTPServerRequest req, HTTPServerResponse res) {
  auto uri = getPath(server.options.contextPath, req);
  auto profile = server.config.getProfile(uri);
  if (basicAuth(req, res, profile)) {
    try {
      if (server.repository.remove(profile, uri)) {
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

//fixme for realname detection
void download(const(Profile) profile, HTTPServerRequest req, HTTPServerResponse res, string path) {
  import std.path;

  auto ext = extension(path);
  if (ext in server.repository.images) {
    sendFile(req, res, server.repository.base ~ path, null);
  } else {
    auto realname = server.repository.getRealname(profile, path[profile.base.length .. $]);
    if (realname.length > 0) {
      void setContextDisposition(scope HTTPServerRequest req, scope HTTPServerResponse res, ref string physicalPath) @safe {
        res.headers["Content-Disposition"] = encodeAttachmentName(realname);
      }

      auto settings = new CacheSetting;
      settings.preWriteCallback = &setContextDisposition;
      sendFile(req, res, server.repository.base ~ path, settings);
    } else {
      sendFile(req, res, server.repository.base ~ path, null);
    }
  }
}

bool checkToken(const(Profile) profile, string uri, string user, string key, string token, string timestamp) {
  try {
    return profile.verifyToken(uri, user, key, token, SysTime.fromISOString(timestamp));
  } catch (Exception e) {
    return false;
  }
}

bool basicAuth(HTTPServerRequest req, HTTPServerResponse res, const(Profile) profile) {
  bool checkPassword(string user, string password) @safe {
    return !user.empty && !password.empty && profile.keys.get(user, "") == password;
  }

  import std.functional : toDelegate;

  if (!checkBasicAuth(req, toDelegate(&checkPassword))) {
    res.statusCode = HTTPStatus.unauthorized;
    res.contentType = "text/plain";
    res.headers["WWW-Authenticate"] = "Basic realm=\"micdn\"";
    res.bodyWriter.write("Authorization required");
    return false;
  } else {
    return true;
  }
}

bool s3Auth(HTTPServerRequest req, HTTPServerResponse res) {
  // Implement AWS Signature V4 authentication
  if ("Authorization" in req.headers) {
    auto authHeader = req.headers["Authorization"];
    if (authHeader.startsWith("AWS4-HMAC-SHA256 ")) {
      // Parse Authorization header
      auto authParts = authHeader[17 .. $].split(", ");
      string credentialScope, signature;

      foreach (part; authParts) {
        if (part.startsWith("Credential=")) {
          credentialScope = part[10 .. $];
        } else if (part.startsWith("Signature=")) {
          signature = part[10 .. $];
        }
      }

      if (!credentialScope.empty && !signature.empty) {
        // Extract access key from credential scope
        auto credentialParts = credentialScope.split("/");
        if (credentialParts.length >= 5) {
          auto accessKey = credentialParts[0];

          // Get the profile for the requested URL
          auto uri = getPath(server.options.contextPath, req);
          if (uri.startsWith("/s3")) {
            uri = uri[3 .. $];
            if (uri.empty)
              uri = "/";
          }
          auto profile = server.config.getProfile(uri);

          // Check if access key exists in profile keys
          if (accessKey in profile.keys) {
            // Get secret key
            auto secretKey = profile.keys[accessKey];

            // Generate canonical request
            string canonicalRequest = generateCanonicalRequest(req, uri);

            // Generate string to sign
            string stringToSign = generateStringToSign(req, canonicalRequest, credentialScope);

            // Generate signature
            string expectedSignature = generateSignature(stringToSign, secretKey, credentialParts[1], credentialParts[2]);

            // Verify signature
            if (signature == expectedSignature) {
              return true;
            }
          }
        }
      }
    }
  }

  res.statusCode = HTTPStatus.unauthorized;
  res.headers["WWW-Authenticate"] = "AWS4-HMAC-SHA256";
  res.writeBody("Unauthorized", "text/plain");
  return false;
}

string generateCanonicalRequest(HTTPServerRequest req, string uri) {
  // Generate canonical request
  string method = req.method.to!string;
  string canonicalUri = uri;
  string canonicalQueryString = "";

  // Handle query parameters
  if (!req.query.empty) {
    bool first = true;
    foreach (kv; req.query.byKeyValue()) {
      if (!first)
        canonicalQueryString ~= "&";
      canonicalQueryString ~= kv.key ~ "=" ~ kv.value;
      first = false;
    }
  }

  // Generate canonical headers
  string canonicalHeaders = "";
  foreach (e; req.headers.byKeyValue()) {
    auto lowerKey = e.key.toLower();
    canonicalHeaders ~= lowerKey ~ ":" ~ e.value.strip() ~ "\n";
  }

  // Generate signed headers
  string signedHeaders = "";
  bool first = true;
  foreach (e; req.headers.byKeyValue()) {
    auto lowerKey = e.key.toLower();
    if (!first)
      signedHeaders ~= ";";
    signedHeaders ~= lowerKey;
    first = false;
  }

  // Generate payload hash
  string payloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
  // In a real implementation, we would hash the request body

  // Combine all parts
  return method ~ "\n" ~ canonicalUri ~ "\n" ~ canonicalQueryString ~ "\n" ~ canonicalHeaders ~ "\n" ~ signedHeaders ~ "\n" ~ payloadHash;
}

string generateStringToSign(HTTPServerRequest req, string canonicalRequest, string credentialScope) {
  // Get timestamp from x-amz-date header
  string timestamp;
  if ("x-amz-date" in req.headers) {
    timestamp = req.headers["x-amz-date"];
  } else {
    // Fallback to current time
    import std.datetime.systime;
    import std.datetime.timezone;

    auto now = Clock.currTime();
    timestamp = now.toISOString();
  }

  // Generate scope from credential scope
  auto scopeParts = credentialScope.split("/");
  string s = scopeParts[1] ~ "/" ~ scopeParts[2] ~ "/s3/aws4_request";

  // Hash canonical request
  import std.digest.sha;
  import std.digest : toHexString, LetterCase;

  auto canonicalRequestHash = toHexString!(LetterCase.lower)(sha256Of(canonicalRequest)).idup;

  // Combine all parts
  return "AWS4-HMAC-SHA256\n" ~ timestamp ~ "\n" ~ s ~ "\n" ~ canonicalRequestHash;
}

void s3Handle(HTTPServerRequest req, HTTPServerResponse res) {
  auto uri = getPath(server.options.contextPath, req);

  // Get the actual URI by removing /s3 prefix
  string actualUri = uri;
  if (actualUri.startsWith("/s3")) {
    actualUri = actualUri[3 .. $];
    if (actualUri.empty)
      actualUri = "/";
  }

  // Authenticate S3 request
  if (s3Auth(req, res)) {
    // Handle S3 request based on HTTP method
    switch (req.method) {
    case HTTPMethod.GET:
      if (actualUri.endsWith("/")) {
        s3ListObjects(req, res, actualUri);
      } else {
        s3GetObject(req, res, actualUri);
      }
      break;
    case HTTPMethod.PUT:
      s3PutObject(req, res, actualUri);
      break;
    case HTTPMethod.DELETE:
      s3DeleteObject(req, res, actualUri);
      break;
    case HTTPMethod.HEAD:
      s3HeadObject(req, res, actualUri);
      break;
    default:
      res.statusCode = HTTPStatus.methodNotAllowed;
      res.writeBody("Method not allowed", "text/plain");
    }
  }
}

void s3GetObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
  // Implement S3 GetObject
  auto rs = server.repository.check(uri);
  if (rs == 2) {
    auto profile = server.config.getProfile(uri);

    // Add S3-specific response headers
    string requestId = generateUuid();
    string amzId2 = generateAmzId2();
    res.headers["x-amz-request-id"] = requestId;
    res.headers["x-amz-id-2"] = amzId2;

    download(profile, req, res, uri);
  } else {
    // S3-style error response
    res.statusCode = HTTPStatus.notFound;
    res.contentType = "application/xml";
    res.writeBody(`<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>NoSuchKey</Code>
  <Message>The specified key does not exist.</Message>
  <Key>`
        ~ uri ~ `</Key>f
  <RequestId>`
        ~ generateUuid() ~ `</RequestId>
  <HostId>`
        ~ generateAmzId2() ~ `</HostId>
</Error>`, "application/xml");
  }
}

void s3PutObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
  // Implement S3 PutObject
  auto profile = server.config.getProfile(uri);
  try {
    import vibe.core.path;
    import std.file;

    // Create temp file
    auto tempPath = std.file.tempDir() ~ "/" ~ generateUuid();
    auto tempFile = File(tempPath, "wb");

    // Read request body to temp file
    ubyte[] buffer = new ubyte[4096];
    size_t read;
    import eventcore.driver : IOMode;

    while ((read = req.bodyReader.read(buffer, IOMode.all)) > 0) {
      tempFile.rawWrite(buffer[0 .. read]);
    }
    tempFile.close();

    // Get filename from uri
    import std.path;

    auto filename = uri.baseName();

    // Create blob meta
    import vibe.inet.mimetypes;

    auto mediaType = getMimeTypeForFile(filename);
    string owner = "s3-user";

    auto meta = server.repository.create(profile, tempPath, filename, uri.dirName(), owner, mediaType);

    // Clean up temp file
    std.file.remove(tempPath);

    // Add S3-specific response headers
    string requestId = generateUuid();
    string amzId2 = generateAmzId2();
    res.headers["x-amz-request-id"] = requestId;
    res.headers["x-amz-id-2"] = amzId2;
    res.headers["ETag"] = "\"" ~ meta.sha ~ "\"";

    res.statusCode = HTTPStatus.ok;
    res.writeBody("", "");
  } catch (Exception e) {
    // S3-style error response
    res.statusCode = HTTPStatus.internalServerError;
    res.contentType = "application/xml";
    res.writeBody(`<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>InternalError</Code>
  <Message>We encountered an internal error. Please try again.</Message>
  <RequestId>`
        ~ generateUuid() ~ `</RequestId>
  <HostId>`
        ~ generateAmzId2() ~ `</HostId>
</Error>`, "application/xml");
  }
}

void s3DeleteObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
  // Implement S3 DeleteObject
  auto profile = server.config.getProfile(uri);
  if (server.repository.remove(profile, uri)) {
    // Add S3-specific response headers
    string requestId = generateUuid();
    string amzId2 = generateAmzId2();
    res.headers["x-amz-request-id"] = requestId;
    res.headers["x-amz-id-2"] = amzId2;

    res.statusCode = HTTPStatus.noContent;
    res.writeBody("", "");
  } else {
    // S3-style error response
    res.statusCode = HTTPStatus.notFound;
    res.contentType = "application/xml";
    res.writeBody(`<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>NoSuchKey</Code>
  <Message>The specified key does not exist.</Message>
  <Key>`
        ~ uri ~ `</Key>
  <RequestId>`
        ~ generateUuid() ~ `</RequestId>
  <HostId>`
        ~ generateAmzId2() ~ `</HostId>
</Error>`, "application/xml");
  }
}

void s3HeadObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
  // Implement S3 HeadObject
  auto rs = server.repository.check(uri);
  if (rs == 2) {
    auto profile = server.config.getProfile(uri);
    import std.file;

    auto filePath = server.repository.base ~ uri;
    auto fileSize = getSize(filePath);

    // Add S3-specific response headers
    string requestId = generateUuid();
    string amzId2 = generateAmzId2();
    string etag = generateEtag(filePath);
    res.headers["x-amz-request-id"] = requestId;
    res.headers["x-amz-id-2"] = amzId2;
    res.headers["Content-Length"] = fileSize.to!string;
    res.headers["Content-Type"] = "application/octet-stream";
    res.headers["ETag"] = etag;

    res.statusCode = HTTPStatus.ok;
    res.writeBody("", "");
  } else {
    // S3-style error response
    res.statusCode = HTTPStatus.notFound;
    res.contentType = "application/xml";
    res.writeBody(`<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>NoSuchKey</Code>
  <Message>The specified key does not exist.</Message>
  <Key>`
        ~ uri ~ `</Key>
  <RequestId>`
        ~ generateUuid() ~ `</RequestId>
  <HostId>`
        ~ generateAmzId2() ~ `</HostId>
</Error>`, "application/xml");
  }
}

void s3ListObjects(HTTPServerRequest req, HTTPServerResponse res, string uri) {
  // Implement S3 ListObjects
  auto profile = server.config.getProfile(uri);
  import std.file;

  auto basePath = server.repository.base ~ uri;
  if (exists(basePath) && isDir(basePath)) {
    // Add S3-specific response headers
    string requestId = generateUuid();
    string amzId2 = generateAmzId2();
    res.headers["x-amz-request-id"] = requestId;
    res.headers["x-amz-id-2"] = amzId2;

    // Generate XML response using core function
    string xmlResponse = generateListObjectsXml(basePath, uri);
    res.contentType = "application/xml";
    res.writeBody(xmlResponse, "application/xml");
  } else {
    // S3-style error response
    res.statusCode = HTTPStatus.notFound;
    res.contentType = "application/xml";
    res.writeBody(`<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>NoSuchBucket</Code>
  <Message>The specified bucket does not exist.</Message>
  <BucketName>`
        ~ uri ~ `</BucketName>
  <RequestId>`
        ~ generateUuid() ~ `</RequestId>
  <HostId>`
        ~ generateAmzId2() ~ `</HostId>
</Error>`, "application/xml");
  }
}
