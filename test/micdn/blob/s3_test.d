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

import micdn.blob.s3;
import std.uuid;
import std.file;
import std.path;
import std.stdio;
import std.algorithm;

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

  string expectedSignature = "0f0ae5caafa9a7f5de9baf7f5b7f2b1c391ba4ee6febb980c774cee5e77b2558";
  string actualSignature = generateSignature(stringToSign, secretKey, date, region);
  assert(actualSignature == expectedSignature, "Signature verification failed");
  assert(actualSignature.length == 64, "Signature length should be 64 characters");
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
