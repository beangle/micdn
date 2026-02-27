module micdn.blob.s3;
/// S3 兼容接口的签名计算与 ListObjects XML 生成工具。

import std.algorithm;
import std.base64;
import std.stdio;
import std.conv : to;
import std.datetime.systime;
import std.digest : toHexString, LetterCase;
import std.digest.hmac;
import std.digest.md;
import std.digest.sha;
import std.file;
import std.path;
import std.random;
import std.range;
import std.uuid;
import std.uni : toLower;
import std.string : strip;

import vibe.core.core;
import vibe.core.file;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.web.web;

import micdn.blob.store;
import micdn.model;
import micdn.web;
import micdn.web.file;

/**
 * AWS Signature V4 utilities for S3 protocol
 */

/**
 * Generate a random UUID v4 string
 *
 * Returns:
 *   A UUID v4 string in the format xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
 */
string generateUuid() {
  return randomUUID().toString();
}

/**
 * Generate a random string for x-amz-id-2
 *
 * Returns:
 *   A random string suitable for x-amz-id-2 header
 */
string generateAmzId2() {
  ubyte[32] bytes;
  auto rng = rndGen();
  foreach (ref b; bytes) { // ref 直接修改数组元素
    b = uniform(cast(ubyte) 0, cast(ubyte) 256, rng); // 生成 0-255 的随机 ubyte
  }
  return Base64.encode(bytes);
}

/**
 * Generate ETag for a file based on its modification time and size
 *
 * Params:
 *   filePath = The path to the file
 *
 * Returns:
 *   The ETag as a quoted string
 */
string generateEtag(string filePath) {
  try {
    auto lastModified = timeLastModified(filePath);
    auto size = getSize(filePath);
    // Combine modification time and size to generate ETag
    auto digest = md5Of(lastModified.toString() ~ ":" ~ size.to!string);
    return `"` ~ toHexString!(LetterCase.lower)(digest).idup ~ `"`;
  } catch (Exception e) {
    // Fallback to dummy ETag if file read fails
    return `"dummy-etag"`;
  }
}

/**
 * Generate AWS Signature V4 signature
 *
 * Params:
 *   stringToSign = The string to sign
 *   secretKey = The secret access key
 *   date = The date part (YYYYMMDD)
 *   region = The AWS region
 *
 * Returns:
 *   The generated signature as a hex string
 */
string generateSignature(string stringToSign, string secretKey, string date, string region) {
  // Generate signing key
  import std.string : representation;

  // Step 1: HMAC with "AWS4" + secretKey as key
  auto hmac = hmac!SHA256(("AWS4" ~ secretKey).representation);
  hmac.put(date.representation);
  hmac.put(region.representation);
  hmac.put("s3".representation);
  hmac.put("aws4_request".representation);
  hmac.put(stringToSign.representation);

  return hmac.finish().toHexString!(LetterCase.lower).idup;
}

/**
 * Generate S3 ListObjects XML response
 *
 * Params:
 *   basePath = The base directory path to list
 *   uriPrefix = The URI prefix for the objects
 *   bucketName = The bucket name to include in the response
 *
 * Returns:
 *   The generated XML response as a string
 */
string generateListObjectsXml(string basePath, string uriPrefix, string bucketName = "micdn-blob") {
  import std.file;
  import std.datetime.systime;
  import std.datetime.timezone;
  import std.array : appender;

  auto app = appender!string();
  app.put(`<?xml version="1.0" encoding="UTF-8"?>` ~ "\n");
  app.put(`<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">` ~ "\n");

  app.put("  <Name>");
  app.put(bucketName);
  app.put("</Name>\n");
  app.put("  <Prefix>");
  app.put(uriPrefix);
  app.put("</Prefix>\n");
  app.put("  <Marker></Marker>\n");
  app.put("  <MaxKeys>1000</MaxKeys>\n");
  app.put("  <IsTruncated>false</IsTruncated>\n");

  foreach (entry; dirEntries(basePath, SpanMode.shallow)) {
    if (isFile(entry)) {
      auto mtime = timeLastModified(entry);
      app.put("  <Contents>\n");
      app.put("    <Key>");
      app.put(uriPrefix ~ entry.baseName());
      app.put("</Key>\n");
      app.put("    <LastModified>");
      app.put(mtime.toISOExtString);
      app.put("</LastModified>\n");
      app.put("    <ETag>");
      app.put(generateEtag(entry));
      app.put("</ETag>\n");
      app.put("    <Size>");
      app.put(getSize(entry).to!string);
      app.put("</Size>\n");
      app.put("  </Contents>\n");
    } else if (entry.isDir) {
      app.put("  <CommonPrefixes>\n");
      app.put("    <Prefix>");
      app.put(uriPrefix ~ entry.baseName() ~ "/");
      app.put("</Prefix>\n");
      app.put("  </CommonPrefixes>\n");
    }
  }

  app.put("</ListBucketResult>\n");
  return app.data;
}

class S3Service {
  private const string endpoint;
  private BlobRepo repo;

  this(MicdnConfig config, MetaDao metadao) {
    this.endpoint = config.blob.endpoint;
    this.repo = BlobRepo.build(config, metadao);
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto uri = getPath(this.endpoint, req);

    // Get the actual URI by removing /s3 prefix
    string actualUri = uri;
    if (actualUri.startsWith("/s3")) {
      actualUri = actualUri[3 .. $];
      if (actualUri.empty)
        actualUri = "/";
    }

    // Authenticate S3 request
    if (auth(req, res)) {
      // Handle S3 request based on HTTP method
      switch (req.method) {
      case HTTPMethod.GET:
        if (actualUri.endsWith("/")) {
          listObjects(req, res, actualUri);
        } else {
          getObject(req, res, actualUri);
        }
        break;
      case HTTPMethod.PUT:
        putObject(req, res, actualUri);
        break;
      case HTTPMethod.DELETE:
        deleteObject(req, res, actualUri);
        break;
      case HTTPMethod.HEAD:
        headObject(req, res, actualUri);
        break;
      default:
        res.statusCode = HTTPStatus.methodNotAllowed;
        res.writeBody("Method not allowed", "text/plain");
      }
    }
  }

  void getObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    // Implement S3 GetObject
    auto rs = repo.check(uri);
    if (rs == 2) {
      auto profile = repo.getProfile(uri);

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
    <Key>` ~ uri ~ `</Key>f
    <RequestId>` ~ generateUuid() ~ `</RequestId>
    <HostId>` ~ generateAmzId2() ~ `</HostId>
  </Error>`, "application/xml");
    }
  }

  void putObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    // Implement S3 PutObject
    auto profile = repo.getProfile(uri);
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

      auto meta = repo.create(profile, tempPath, filename, uri.dirName(), owner, mediaType);

      // Clean up temp file
      std.file.remove(tempPath);

      // Add S3-specific response headers
      string requestId = generateUuid();
      string amzId2 = generateAmzId2();
      res.headers["x-amz-request-id"] = requestId;
      res.headers["x-amz-id-2"] = amzId2;
      res.headers["ETag"] = `"` ~ meta.sha ~ `"`;

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
    <RequestId>` ~ generateUuid() ~ `</RequestId>
    <HostId>` ~ generateAmzId2() ~ `</HostId>
  </Error>`, "application/xml");
    }
  }

  void deleteObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    // Implement S3 DeleteObject
    auto profile = repo.getProfile(uri);
    if (repo.remove(profile, uri)) {
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
    <Key>` ~ uri ~ `</Key>
    <RequestId>` ~ generateUuid() ~ `</RequestId>
    <HostId>` ~ generateAmzId2() ~ `</HostId>
  </Error>`, "application/xml");
    }
  }

  void headObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    // Implement S3 HeadObject
    auto rs = repo.check(uri);
    if (rs == 2) {
      auto profile = repo.getProfile(uri);
      import std.file;

      auto filePath = repo.base ~ uri;
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
    <Key>` ~ uri ~ `</Key>
    <RequestId>` ~ generateUuid() ~ `</RequestId>
    <HostId>` ~ generateAmzId2() ~ `</HostId>
  </Error>`, "application/xml");
    }
  }

  void listObjects(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    // Implement S3 ListObjects
    auto profile = repo.getProfile(uri);
    import std.file;

    auto basePath = repo.base ~ uri;
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
    <BucketName>` ~ uri ~ `</BucketName>
    <RequestId>` ~ generateUuid() ~ `</RequestId>
    <HostId>` ~ generateAmzId2() ~ `</HostId>
  </Error>`, "application/xml");
    }
  }

  private bool auth(HTTPServerRequest req, HTTPServerResponse res) {
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
            auto uri = getPath(this.endpoint, req);
            if (uri.startsWith("/s3")) {
              uri = uri[3 .. $];
              if (uri.empty)
                uri = "/";
            }
            auto profile = repo.getProfile(uri);

            // Check if access key exists in profile keys
            if (accessKey in profile.keys) {
              // Get secret key
              auto secretKey = profile.keys[accessKey];

              // Generate canonical request
              string canonicalRequest = generateCanonicalRequest(req, uri);

              // Generate string to sign
              string stringToSign = generateStringToSign(req, canonicalRequest, credentialScope);

              // Generate signature
              string expectedSignature = generateSignature(stringToSign,
                  secretKey, credentialParts[1], credentialParts[2]);

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
    return method ~ "\n" ~ canonicalUri ~ "\n" ~ canonicalQueryString ~ "\n"
      ~ canonicalHeaders ~ "\n" ~ signedHeaders ~ "\n" ~ payloadHash;
  }

  string generateStringToSign(HTTPServerRequest req, string canonicalRequest,
      string credentialScope) {
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

  //fixme for realname detection
  private void download(const(BlobProfile) profile, HTTPServerRequest req,
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
        settings.preWriteCallback = &setContextDisposition;
        sendFile(req, res, repo.base ~ path, settings);
      } else {
        sendFile(req, res, repo.base ~ path, null);
      }
    }
  }
}
