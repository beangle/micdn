/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.blob.store_test;

import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.uuid : randomUUID;

import micdn.blob.store;
import micdn.blob.xattr;

@("blob bucket key from host (host resolve style)")
unittest {
  assert(blobBucketKeyFromHost("localhost") == "localhost");
  assert(blobBucketKeyFromHost("127.0.0.1") == "localhost");
  assert(blobBucketKeyFromHost("127.0.0.1:8080") == "localhost");
  assert(blobBucketKeyFromHost("192.168.31.125") == "192");
  assert(blobBucketKeyFromHost("bucket1.example.com") == "bucket1");
  assert(blobBucketKeyFromHost("single") == "single");
  assert(blobBucketKeyFromHost("") == "");
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
