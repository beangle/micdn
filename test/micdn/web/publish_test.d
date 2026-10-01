/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.web.publish_test;

import std.base64 : Base64;
import std.exception : assertThrown;

import vibe.http.common : HTTPStatus, HTTPStatusException;
import vibe.stream.memory : createMemoryStream;

import micdn.web.publish : decodeBase64Loose, readUploadBody, secureEquals, tokenAccepted;

private ubyte[] sampleBytes(size_t n) {
  auto data = new ubyte[n];
  foreach (i; 0 .. n)
    data[i] = cast(ubyte) (i % 251);
  return data;
}

@("readUploadBody reads a body larger than one internal buffer")
unittest {
  auto data = sampleBytes(5000);
  assert(readUploadBody(createMemoryStream(data), 10 * 1024) == data);
  assert(readUploadBody(createMemoryStream(null), 16).length == 0);
}

@("readUploadBody rejects a body above the limit with 413")
unittest {
  try {
    readUploadBody(createMemoryStream(sampleBytes(256)), 100);
    assert(false, "expected 413");
  } catch (HTTPStatusException e) {
    assert(e.status == HTTPStatus.requestEntityTooLarge);
  }
}

@("tokenAccepted accepts Bearer, Basic and X-Micdn-Token, rejects everything else")
unittest {
  assert(tokenAccepted("s3cret", "s3cret", ""));
  assert(tokenAccepted("s3cret", "", "Bearer s3cret"));
  assert(tokenAccepted("s3cret", "", "bearer s3cret"), "auth scheme is case-insensitive");
  // Maven 的 settings.xml 凭据走 Basic，用户名/口令放在哪一侧都可能
  assert(tokenAccepted("s3cret", "", "Basic " ~ Base64.encode(cast(const(ubyte)[]) "u:s3cret")));
  assert(tokenAccepted("s3cret", "", "Basic " ~ Base64.encode(cast(const(ubyte)[]) "s3cret:x")));
  assert(tokenAccepted("s3cret", "", "Basic " ~ Base64.encode(cast(const(ubyte)[]) "s3cret")));
  assert(!tokenAccepted("s3cret", "", "Bearer wrong"));
  assert(!tokenAccepted("s3cret", "", "Basic bm90LWJhc2U2NA"));  // 解出来是别的口令
  assert(!tokenAccepted("s3cret", "wrong", ""));
  assert(!tokenAccepted("s3cret", "", ""));
  assert(!tokenAccepted("", "s3cret", "Bearer s3cret"), "未启用发布（空令牌）时一律拒绝");
}

@("secureEquals compares full content and rejects different lengths")
unittest {
  assert(secureEquals("abc", "abc"));
  assert(!secureEquals("abc", "abd"));
  assert(!secureEquals("abc", "ab"));
  assert(secureEquals("", ""));
}

@("decodeBase64Loose tolerates missing padding")
unittest {
  assert(decodeBase64Loose("aGVsbG8=") == cast(const(ubyte)[]) "hello");
  assert(decodeBase64Loose("aGVsbG8") == cast(const(ubyte)[]) "hello");
  assertThrown(decodeBase64Loose("!!!"));
}
