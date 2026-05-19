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

module micdn.blob.s3;
/// S3 兼容接口：挂载在 `micdn.routes.mountS3`，路径解析与 Blob 相同（path 风格首段为 bucket）。

import core.time : Duration, dur;

import std.algorithm;
import std.array : appender, join;
import std.ascii : isDigit, isHexDigit;
import std.base64;
import std.stdio;
import std.conv : to;
import std.datetime.date : DateTime;
import std.datetime.systime;
import std.datetime.timezone : UTC;
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
import std.string : representation, split, strip;
import std.uri : encodeComponent;

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

enum sigV4Algorithm = "AWS4-HMAC-SHA256";
enum sigV4Service = "s3";
enum sigV4Terminal = "aws4_request";
enum sigV4UnsignedPayload = "UNSIGNED-PAYLOAD";
enum sigV4EmptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

struct SigV4Authorization {
  string accessKey;
  string date;
  string region;
  string service;
  string terminal;
  string credentialScope;
  string signature;
  string[] signedHeaders;
}

private ubyte[32] hmacSha256(const(ubyte)[] key, string data) {
  auto h = hmac!SHA256(key);
  h.put(data.representation);
  return h.finish();
}

/// Derive the AWS SigV4 signing key for `date/region/s3/aws4_request`.
ubyte[32] deriveSigningKey(string secretKey, string date, string region) {
  auto kDate = hmacSha256(("AWS4" ~ secretKey).representation, date);
  auto kRegion = hmacSha256(kDate[], region);
  auto kService = hmacSha256(kRegion[], sigV4Service);
  return hmacSha256(kService[], sigV4Terminal);
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
  auto signingKey = deriveSigningKey(secretKey, date, region);
  return hmacSha256(signingKey[], stringToSign).toHexString!(LetterCase.lower).idup;
}

bool parseSigV4Authorization(string authHeader, out SigV4Authorization parsed) {
  parsed = SigV4Authorization.init;
  if (!authHeader.startsWith(sigV4Algorithm ~ " "))
    return false;

  string credential;
  string signedHeaders;
  foreach (part; authHeader[(sigV4Algorithm.length + 1) .. $].split(",")) {
    part = part.strip();
    if (part.startsWith("Credential=")) {
      credential = part["Credential=".length .. $].strip();
    } else if (part.startsWith("SignedHeaders=")) {
      signedHeaders = part["SignedHeaders=".length .. $].strip();
    } else if (part.startsWith("Signature=")) {
      parsed.signature = part["Signature=".length .. $].strip();
    }
  }

  auto credentialParts = credential.split("/");
  if (credentialParts.length != 5 || signedHeaders.length == 0 || !isHexSha256(parsed.signature))
    return false;

  parsed.accessKey = credentialParts[0];
  parsed.date = credentialParts[1];
  parsed.region = credentialParts[2];
  parsed.service = credentialParts[3];
  parsed.terminal = credentialParts[4];
  parsed.credentialScope = parsed.date ~ "/" ~ parsed.region ~ "/" ~ parsed.service ~ "/" ~ parsed.terminal;

  string previousHeader;
  foreach (header; signedHeaders.split(";")) {
    header = header.strip().toLower();
    if (header.length == 0)
      return false;
    if (previousHeader.length > 0 && header <= previousHeader)
      return false;
    parsed.signedHeaders ~= header;
    previousHeader = header;
  }
  return parsed.service == sigV4Service && parsed.terminal == sigV4Terminal;
}

bool signedHeadersContain(const string[] signedHeaders, string headerName) {
  auto target = headerName.toLower();
  return signedHeaders.canFind!(h => h == target);
}

bool parseAmzDate(string timestamp, out SysTime parsed) {
  timestamp = timestamp.strip();
  if (timestamp.length != 16 || timestamp[8] != 'T' || timestamp[15] != 'Z')
    return false;

  foreach (i, c; timestamp) {
    if (i == 8 || i == 15)
      continue;
    if (!c.isDigit)
      return false;
  }

  try {
    int year = timestamp[0 .. 4].to!int;
    int month = timestamp[4 .. 6].to!int;
    int day = timestamp[6 .. 8].to!int;
    int hour = timestamp[9 .. 11].to!int;
    int minute = timestamp[11 .. 13].to!int;
    int second = timestamp[13 .. 15].to!int;
    parsed = SysTime(DateTime(year, month, day, hour, minute, second), UTC());
    return true;
  } catch (Exception e) {
    return false;
  }
}

bool timestampWithinWindow(string timestamp, Duration maxSkew = dur!"minutes"(15)) {
  SysTime requestTime;
  if (!parseAmzDate(timestamp, requestTime))
    return false;

  auto now = Clock.currTime(UTC());
  return now >= requestTime - maxSkew && now <= requestTime + maxSkew;
}

bool isValidPayloadHash(string payloadHash) {
  if (payloadHash == sigV4UnsignedPayload)
    return true;
  return isHexSha256(payloadHash);
}

bool isHexSha256(string value) {
  if (value.length != 64)
    return false;
  return value.all!(c => c.isHexDigit);
}

bool getHeaderValue(HTTPServerRequest req, string headerName, out string value) {
  auto exact = headerName in req.headers;
  if (exact !is null) {
    value = *exact;
    return true;
  }

  auto lowerName = headerName.toLower();
  foreach (entry; req.headers.byKeyValue()) {
    if (entry.key.toLower() == lowerName) {
      value = entry.value;
      return true;
    }
  }
  return false;
}

string canonicalHeaderValue(string value) {
  auto normalized = appender!string();
  bool inWhitespace = false;
  foreach (c; value.strip()) {
    if (c == ' ' || c == '\t') {
      inWhitespace = true;
    } else {
      if (inWhitespace && normalized.data.length > 0)
        normalized.put(' ');
      normalized.put(c);
      inWhitespace = false;
    }
  }
  return normalized.data;
}

string canonicalQueryString(HTTPServerRequest req) {
  string[] parts;
  foreach (kv; req.query.byKeyValue()) {
    parts ~= kv.key.encodeComponent ~ "=" ~ kv.value.encodeComponent;
  }
  parts.sort();
  return parts.join("&");
}

bool generateCanonicalRequest(HTTPServerRequest req, string uri, const string[] signedHeaders,
    string payloadHash, out string canonicalRequest) {
  auto canonicalHeaders = appender!string();
  foreach (header; signedHeaders) {
    string value;
    if (!getHeaderValue(req, header, value))
      return false;
    canonicalHeaders.put(header);
    canonicalHeaders.put(":");
    canonicalHeaders.put(canonicalHeaderValue(value));
    canonicalHeaders.put("\n");
  }

  string signedHeadersValue = signedHeaders.join(";");
  string canonicalUri = uri.length == 0 ? "/" : uri;
  canonicalRequest = req.method.to!string ~ "\n" ~ canonicalUri ~ "\n" ~ canonicalQueryString(req)
    ~ "\n" ~ canonicalHeaders.data ~ "\n" ~ signedHeadersValue ~ "\n" ~ payloadHash;
  return true;
}

string generateStringToSign(string amzDate, string credentialScope, string canonicalRequest) {
  auto canonicalRequestHash = toHexString!(LetterCase.lower)(sha256Of(canonicalRequest)).idup;
  return sigV4Algorithm ~ "\n" ~ amzDate ~ "\n" ~ credentialScope ~ "\n" ~ canonicalRequestHash;
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
  private BlobRepo repo;

  this(BlobRepo repo) {
    this.repo = repo;
  }

  void service(HTTPServerRequest req, HTTPServerResponse res) {
    auto actualUri = getPath(mountS3, req);

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
    auto br = repo.resolveBlob(uri);
    if (br.bucket.name.length == 0 || repo.check(br.bucket, br.objectPath) != 2) {
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
      return;
    }
    string requestId = generateUuid();
    string amzId2 = generateAmzId2();
    res.headers["x-amz-request-id"] = requestId;
    res.headers["x-amz-id-2"] = amzId2;

    import micdn.blob.web;

    sendObject(repo, br.bucket, br.objectPath, req, res);
  }

  void putObject(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    auto br = repo.resolveBlob(uri);
    try {
      import vibe.core.path;
      import std.file;

      string signedPayloadHash;
      bool bindPayloadHash = getHeaderValue(req, "x-amz-content-sha256", signedPayloadHash)
        && signedPayloadHash != sigV4UnsignedPayload;
      auto payloadHasher = SHA256();

      // Create temp file
      auto tempPath = std.file.tempDir() ~ "/" ~ generateUuid();
      auto tempFile = File(tempPath, "wb");

      // Read request body to temp file
      ubyte[] buffer = new ubyte[4096];
      size_t read;
      import eventcore.driver : IOMode;

      while ((read = req.bodyReader.read(buffer, IOMode.all)) > 0) {
        if (bindPayloadHash)
          payloadHasher.put(buffer[0 .. read]);
        tempFile.rawWrite(buffer[0 .. read]);
      }
      tempFile.close();

      if (bindPayloadHash) {
        auto actualPayloadHash = payloadHasher.finish().toHexString!(LetterCase.lower).idup;
        if (actualPayloadHash != signedPayloadHash) {
          std.file.remove(tempPath);
          res.statusCode = HTTPStatus.unauthorized;
          res.headers["WWW-Authenticate"] = sigV4Algorithm;
          res.writeBody("Unauthorized", "text/plain");
          return;
        }
      }

      // Get filename from uri
      import std.path;

      auto filename = br.objectPath.baseName();

      string owner = "s3-user";

      auto meta = repo.create(br.bucket, tempPath, filename,
          blobObjectUploadDir(br.objectPath), owner);

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
    auto br = repo.resolveBlob(uri);
    if (repo.remove(br.bucket, br.objectPath)) {
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
    auto br = repo.resolveBlob(uri);
    if (br.bucket.name.length == 0 || repo.check(br.bucket, br.objectPath) != 2) {
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
      return;
    }
    import std.file;

    auto filePath = repo.toPhysicalPath(br.bucket, br.objectPath);
    auto fileSize = getSize(filePath);

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
  }

  void listObjects(HTTPServerRequest req, HTTPServerResponse res, string uri) {
    auto br = repo.resolveBlob(uri);
    if (br.bucket.name.length == 0) {
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
      return;
    }
    import std.file;

    auto basePath = repo.toPhysicalPath(br.bucket, br.objectPath);
    if (!basePath.empty && exists(basePath) && isDir(basePath)) {
      string requestId = generateUuid();
      string amzId2 = generateAmzId2();
      res.headers["x-amz-request-id"] = requestId;
      res.headers["x-amz-id-2"] = amzId2;

      string xmlResponse = generateListObjectsXml(basePath, uri);
      res.contentType = "application/xml";
      res.writeBody(xmlResponse, "application/xml");
    } else {
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
    string authHeader;
    SigV4Authorization sigv4;
    if (getHeaderValue(req, "Authorization", authHeader) && parseSigV4Authorization(authHeader, sigv4)) {
      string amzDate;
      string payloadHash;
      auto uri = getPath(mountS3, req);
      auto br = repo.resolveBlob(uri);

      // Access Key 固定为 micdn，Secret 为 micdn.xml 中 bucket 的 key
      if (sigv4.accessKey == "micdn" && br.bucket.key.length > 0
          && signedHeadersContain(sigv4.signedHeaders, "host")
          && signedHeadersContain(sigv4.signedHeaders, "x-amz-date")
          && getHeaderValue(req, "x-amz-date", amzDate)
          && timestampWithinWindow(amzDate)
          && amzDate[0 .. 8] == sigv4.date
          && getHeaderValue(req, "x-amz-content-sha256", payloadHash)
          && isValidPayloadHash(payloadHash)) {
        string canonicalRequest;
        if (generateCanonicalRequest(req, uri, sigv4.signedHeaders, payloadHash, canonicalRequest)) {
          auto stringToSign = generateStringToSign(amzDate, sigv4.credentialScope, canonicalRequest);
          auto expectedSignature = generateSignature(stringToSign, br.bucket.key, sigv4.date, sigv4.region);
          if (sigv4.signature == expectedSignature)
            return true;
        }
      }
    }

    res.statusCode = HTTPStatus.unauthorized;
    res.headers["WWW-Authenticate"] = "AWS4-HMAC-SHA256";
    res.writeBody("Unauthorized", "text/plain");
    return false;
  }
}
