/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.blob.store_test;

import std.exception : assertThrown;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.uuid : randomUUID;

import micdn.blob.store;
import micdn.blob.xattr;
import micdn.model;

@("blobObjectUploadDir upload path semantics")
unittest {
  assert(blobObjectUploadDir("/a/b/c/file.txt") == "/a/b/c");
  assert(blobObjectUploadDir("/a/b/c/") == "/a/b/c");
  assert(blobObjectUploadDir("/a/b/c") == "/a/b");
}

@("blob object path rejects traversal segments")
unittest {
  assert(isSafeBlobObjectPath("/a/b/file.txt"));
  assert(isSafeBlobObjectPath("/a..b/file.txt"));
  assert(!isSafeBlobObjectPath("/../secret.txt"));
  assert(!isSafeBlobObjectPath("/a/%2e%2e/secret.txt"));
  assert(!isSafeBlobObjectPath("/a/%5csecret.txt"));
}

@("blob path-style bucket split")
unittest {
  string b, p;
  assert(blobPathSplitBucket("/local/foo/bar", b, p) && b == "local" && p == "/foo/bar");
  assert(blobPathSplitBucket("/local", b, p) && b == "local" && p == "/");
  assert(!blobPathSplitBucket("nope", b, p));
  assert(!blobPathSplitBucket("", b, p));
}

@("blob repo rejects unsafe object paths")
unittest {
  auto base = buildPath(tempDir(), "micdn-blob-safe-" ~ randomUUID().toString);
  scope (exit) {
    if (exists(base))
      rmdirRecurse(base);
  }

  auto config = new BlobConfig(base);
  config.buckets = [Bucket("local", "secret", true)];
  auto repo = new BlobRepo(config);
  auto bucket = config.buckets[0];

  assert(repo.toPhysicalPath(bucket, "/safe/file.txt").length > 0);
  assert(repo.toPhysicalPath(bucket, "/../secret.txt").length == 0);
  assert(repo.toPhysicalPath(bucket, "/a/%2e%2e/secret.txt").length == 0);
  assert(repo.check(bucket, "/../secret.txt") == 0);
  assert(!repo.remove(bucket, "/../secret.txt"));

  auto tmp = buildPath(base, "upload.tmp");
  write(tmp, [ubyte(1), 2, 3]);
  assertThrown!Exception(repo.create(bucket, tmp, "file.txt", "/../escape", "me"));
}

version (linux) {
  @("blob user xattr roundtrip")
  unittest {
    string base = buildPath(tempDir(), "micdn-blob-xattr-" ~ randomUUID().toString);
    mkdirRecurse(base);
    scope (exit) {
      if (exists(base))
        rmdirRecurse(base);
    }
    string f = buildPath(base, "t.bin");
    write(f, [ubyte(0), 1, 2]);
    setBlobUserMeta(f, "me", "deadbeef", "n.txt");
    assert(getUserXattr(f, "owner") == "me");
    assert(getUserXattr(f, "sha1") == "deadbeef");
    assert(getUserXattr(f, "original_name") == "n.txt");
    auto xs = listUserXattrs(f);
    assert("owner" in xs && xs["owner"] == "me");
    assert("sha1" in xs);
  }
}
