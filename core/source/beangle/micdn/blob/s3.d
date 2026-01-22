module beangle.micdn.blob.s3;

import std.digest.hmac;
import std.digest.sha;
import std.digest.md;
import std.digest : toHexString, LetterCase;
import std.random;
import std.base64;
import std.datetime.systime;
import std.file;
import std.path;
import std.uuid;
import std.conv : to;

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
    return "\"" ~ toHexString!(LetterCase.lower)(digest).idup ~ "\"";
  } catch (Exception e) {
    // Fallback to dummy ETag if file read fails
    return "\"dummy-etag\"";
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
 * Unit tests for S3 signature generation
 */
unittest {
  // Test case from AWS documentation
  string secretKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
  string date = "20130524";
  string region = "us-east-1";
  string stringToSign = "AWS4-HMAC-SHA256\n" ~ "20130524T000000Z\n" ~ "20130524/us-east-1/s3/aws4_request\n"
    ~ "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972";

  string expectedSignature = "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41";
  string actualSignature = generateSignature(stringToSign, secretKey, date, region);

  assert(actualSignature == expectedSignature, "Signature verification failed");
  assert(actualSignature.length == 64, "Signature length should be 64 characters");
}

unittest {
  // Test with different parameters
  string secretKey = "test-secret-key";
  string date = "20260122";
  string region = "us-west-2";
  string stringToSign = "AWS4-HMAC-SHA256\n" ~ "20260122T120000Z\n" ~ "20260122/us-west-2/s3/aws4_request\n" ~ "test-string-to-sign-hash";

  string signature = generateSignature(stringToSign, secretKey, date, region);

  assert(signature.length == 64, "Signature length should be 64 characters");
  assert(!signature.empty, "Signature should not be empty");
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
  app.put("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
  app.put("<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\n");

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

unittest {
  // Test generateListObjectsResponse function
  import std.file;
  import std.path;

  // Create a temporary directory for testing
  string tempDir = tempDir() ~ "/" ~ tempName();
  mkdirRecurse(tempDir);

  // Create test files and directories
  string testFile = tempDir ~ "/test.txt";
  string testDir = tempDir ~ "/test-dir";

  File(testFile, "w").writeln("test content");
  mkdirRecurse(testDir);

  // Generate response
  string response = generateListObjectsXml(tempDir, "/test-prefix/");

  // Clean up
  remove(testFile);
  remove(testDir);
  remove(tempDir);

  // Verify response
  assert(response.length > 0, "Response should not be empty");
  assert(response.indexOf("ListBucketResult") > -1, "Response should contain ListBucketResult");
  assert(response.indexOf("test.txt") > -1, "Response should contain test file");
  assert(response.indexOf("test-dir/") > -1, "Response should contain test directory");
}
