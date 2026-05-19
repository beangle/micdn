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

module test.micdn.blob.s3_test;

import core.time : dur;

import micdn.blob.s3;
import std.uuid;
import std.file;
import std.path;
import std.stdio;
import std.algorithm;
import std.datetime.systime;
import std.digest : LetterCase, toHexString;
import vibe.http.common : HTTPMethod;
import vibe.http.server : createTestHTTPServerRequest;
import vibe.inet.message : InetHeaderMap;
import vibe.inet.url : URL;

/**
 * Unit tests for S3 signature generation
 */
@("s3 signature from aws docs")
unittest {
  // Test case from AWS documentation
  string secretKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
  string date = "20130524";
  string region = "us-east-1";
  string stringToSign = "AWS4-HMAC-SHA256\n" ~ "20130524T000000Z\n" ~ "20130524/us-east-1/s3/aws4_request\n"
    ~ "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972";

  string expectedSignature = "67fe34c8530db585abddc51067328adfedb6e42487d2566dc7d927d6e2722900";
  string actualSignature = generateSignature(stringToSign, secretKey, date, region);
  assert(actualSignature == expectedSignature, "Signature verification failed");
  assert(actualSignature.length == 64, "Signature length should be 64 characters");
}

@("s3 signing key derivation from chained hmac")
unittest {
  string secretKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
  auto signingKey = deriveSigningKey(secretKey, "20130524", "us-east-1");
  auto actual = toHexString!(LetterCase.lower)(signingKey).idup;
  assert(actual == "f117494eff5d09da21cbf7f0339559ea04fc9582d31299cb992be70a6b27c97a");
}

@("s3 signature custom params")
unittest {
  // Test with different parameters
  string secretKey = "test-secret-key";
  string date = "20260122";
  string region = "us-west-2";
  string stringToSign = "AWS4-HMAC-SHA256\n" ~ "20260122T120000Z\n"
    ~ "20260122/us-west-2/s3/aws4_request\n" ~ "test-string-to-sign-hash";

  string signature = generateSignature(stringToSign, secretKey, date, region);

  assert(signature.length == 64, "Signature length should be 64 characters");
  assert(signature.length > 0, "Signature should not be empty");
}

@("s3 authorization parses credential scope and signed headers")
unittest {
  SigV4Authorization parsed;
  auto authHeader = "AWS4-HMAC-SHA256 "
    ~ "Credential=micdn/20260519/us-east-1/s3/aws4_request, "
    ~ "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
    ~ "Signature=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

  assert(parseSigV4Authorization(authHeader, parsed));
  assert(parsed.accessKey == "micdn");
  assert(parsed.date == "20260519");
  assert(parsed.region == "us-east-1");
  assert(parsed.credentialScope == "20260519/us-east-1/s3/aws4_request");
  assert(parsed.signedHeaders == ["host", "x-amz-content-sha256", "x-amz-date"]);
  assert(signedHeadersContain(parsed.signedHeaders, "Host"));
}

@("s3 authorization rejects unsorted or duplicate signed headers")
unittest {
  SigV4Authorization parsed;
  auto signature = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  auto unsorted = "AWS4-HMAC-SHA256 Credential=micdn/20260519/us-east-1/s3/aws4_request,"
    ~ " SignedHeaders=x-amz-date;host, Signature=" ~ signature;
  auto duplicate = "AWS4-HMAC-SHA256 Credential=micdn/20260519/us-east-1/s3/aws4_request,"
    ~ " SignedHeaders=host;host, Signature=" ~ signature;

  assert(!parseSigV4Authorization(unsorted, parsed));
  assert(!parseSigV4Authorization(duplicate, parsed));
}

@("s3 canonical request uses signed headers and normalized values")
unittest {
  InetHeaderMap headers;
  headers["Host"] = "example.com";
  headers["X-Amz-Date"] = "20260519T060000Z";
  headers["X-Amz-Content-Sha256"] = sigV4UnsignedPayload;
  headers["X-Amz-Meta-Name"] = "  alpha\t beta   gamma  ";

  auto req = createTestHTTPServerRequest(
      URL("https://example.com/bucket/photos/puppy.jpg?b=two&a=one"), HTTPMethod.GET, headers, null);

  string canonicalRequest;
  auto signedHeaders = ["host", "x-amz-content-sha256", "x-amz-date", "x-amz-meta-name"];
  assert(generateCanonicalRequest(req, "/bucket/photos/puppy.jpg", signedHeaders,
      sigV4UnsignedPayload, canonicalRequest));

  auto expected = "GET\n"
    ~ "/bucket/photos/puppy.jpg\n"
    ~ "a=one&b=two\n"
    ~ "host:example.com\n"
    ~ "x-amz-content-sha256:UNSIGNED-PAYLOAD\n"
    ~ "x-amz-date:20260519T060000Z\n"
    ~ "x-amz-meta-name:alpha beta gamma\n"
    ~ "\n"
    ~ "host;x-amz-content-sha256;x-amz-date;x-amz-meta-name\n"
    ~ "UNSIGNED-PAYLOAD";
  assert(canonicalRequest == expected, canonicalRequest);
}

@("s3 timestamp parser and replay window")
unittest {
  SysTime parsed;
  assert(parseAmzDate("20130524T000000Z", parsed));
  assert(!parseAmzDate("20130524T000000", parsed));
  assert(timestampWithinWindow("20130524T000000Z", dur!"days"(100_000)));
  assert(!timestampWithinWindow("20130524T000000Z", dur!"minutes"(15)));
}

@("s3 payload hash accepts unsigned payload and sha256 hex only")
unittest {
  assert(isValidPayloadHash(sigV4UnsignedPayload));
  assert(isValidPayloadHash(sigV4EmptyPayloadHash));
  assert(!isValidPayloadHash("abc"));
  assert(!isValidPayloadHash("g" ~ sigV4EmptyPayloadHash[1 .. $]));
}

@("s3 generate list objects xml")
unittest {
  // Test generateListObjectsResponse function
  import std.file;
  import std.path;
  import std.stdio;
  import std.algorithm;

  // Create a temporary directory for testing
  string tempDir = buildPath(tempDir(), randomUUID().toString());
  mkdirRecurse(tempDir);

  // Create test files and directories
  string testFile = buildPath(tempDir, "test.txt");
  string testDir = buildPath(tempDir, "test-dir");

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
  assert(response.canFind("ListBucketResult"), "Response should contain ListBucketResult");
  assert(response.canFind("test.txt"), "Response should contain test file");
  assert(response.canFind("test-dir/"), "Response should contain test directory");
}
