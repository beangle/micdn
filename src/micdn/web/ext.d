/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.web.ext;
/// 常见文件扩展名集合（小写、含前导 `.`），供 blob 图片鉴权与 www SPA try-file 等复用。

import std.path : baseName, extension;
import std.uni : toLower;

/// 图片扩展名列表（小写、含前导 `.`）。
immutable string[] imageExtensionList = [
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".ico", ".bmp", ".tiff", ".tif", ".avif",
];

/// SPA 静态资源扩展名（不含 `imageExtensionList` 中的项）。
immutable string[] staticAssetExtraExtensionList = [
    ".js", ".mjs", ".cjs", ".css", ".map", ".wasm", ".json", ".webmanifest",
    ".html", ".htm",
    ".woff", ".woff2", ".ttf", ".eot", ".otf",
    ".mp4", ".webm", ".mp3", ".wav", ".ogg",
    ".txt", ".xml",
];

/// 图片扩展名集合，供 O(1) 查找。
immutable bool[string] imageExtensions;

/// www try-file 守卫：图片 + 其它常见静态资源。
immutable bool[string] staticAssetExtensions;

shared static this() {
  bool[string] img, stat;
  foreach (ext; imageExtensionList) {
    img[ext] = true;
    stat[ext] = true;
  }
  foreach (ext; staticAssetExtraExtensionList)
    stat[ext] = true;
  imageExtensions = cast(immutable) img;
  staticAssetExtensions = cast(immutable) stat;
}

pragma(inline, true) bool isImage(string path) @safe pure {
  return hasKnownExtension(path, imageExtensions);
}

pragma(inline, true) bool isStaticAsset(string path) @safe pure {
  return hasKnownExtension(path, staticAssetExtensions);
}

private bool hasKnownExtension(string path, scope immutable bool[string] set) @safe pure {
  auto bn = baseName(path);
  if (bn.length == 0)
    return false;
  auto ext = extension(bn);
  if (ext.length == 0)
    return false;
  return (ext.toLower() in set) !is null;
}
