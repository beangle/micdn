/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.web.ext_test;

import micdn.web.ext;

@("imageExtensions covers blob image types case-insensitively")
unittest {
  assert(isImage("/a/x.JPG"));
  assert(isImage("photo.webp"));
  assert(!isImage("/a/x.pdf"));
}

@("staticAssetExtensions includes scripts and excludes bare routes")
unittest {
  assert(isStaticAsset("/app/chunk.js"));
  assert(isStaticAsset("/app/missing.css"));
  assert(!isStaticAsset("/app/route/foo"));
}
