/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.blob.store;
/// Blob：扩展属性仅存 owner/sha1/original_name；媒体类型与更新时刻由扩展名与文件 mtime 推导。

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.stdio : File;
import std.path;
import std.string;

import std.digest : toHexString, LetterCase;
import std.digest.sha;

import vibe.core.log;
import vibe.inet.mimetypes : getMimeTypeForFile;

import micdn.blob.xattr;
import micdn.model;

/// 解析结果：桶 + 桶内对象路径（以 `/` 开头）。
struct BlobResolve {
  Bucket bucket;
  string objectPath;
}

/** Path 风格：endpoint 之后的路径以 `/` 开头，首段为桶名，其余为对象路径（至少为 `/`）。
    若 `uri` 形如 `/bucket` 则对象路径为 `/`。
*/
bool blobPathSplitBucket(string uri, out string bucketName, out string restPath) {
  if (uri.length <= 1 || uri[0] != '/')
    return false;
  size_t i = 1;
  while (i < uri.length && uri[i] != '/')
    i++;
  bucketName = uri[1 .. i];
  if (bucketName.length == 0)
    return false;
  if (i >= uri.length) {
    restPath = "/";
    return true;
  }
  restPath = uri[i .. $];
  if (restPath.length == 0)
    restPath = "/";
  return true;
}

/** 上传时桶内目标目录（`create` 的 `dir` 参数），仅由 URI 形态决定。

    - 以 `/` 结尾（如 `/a/b/c/`）：目录为 `/a/b/c`。
    - 末段带扩展名（如 `/a/b/c/file.txt`）：`dirName` → `/a/b/c`。
    - 末段无扩展名（如 `/a/b/c`）：`dirName` → `/a/b`（末段视为目录名，文件落在其父级）。
*/
string blobObjectUploadDir(string objectPath) {
  import std.string : strip;

  objectPath = strip(objectPath);
  if (objectPath.length == 0)
    return "/";
  if (!objectPath.startsWith("/"))
    objectPath = "/" ~ objectPath;
  if (objectPath.endsWith("/"))
    return objectPath.length == 1 ? "/" : objectPath[0 .. $-1];
  return dirName(objectPath);
}

/// 校验桶内对象路径：拒绝 NUL、反斜杠，以及原始或 URL 编码后的独立 `..` 路径段。
bool isSafeBlobObjectPath(string objectPath) {
  import vibe.textfilter.urlencode : urlDecode;

  try
    objectPath = urlDecode(objectPath);
  catch (Exception)
    return false;

  if (objectPath.length == 0)
    objectPath = "/";
  else if (!objectPath.startsWith("/"))
    objectPath = "/" ~ objectPath;

  if (objectPath.indexOf('\0') >= 0 || objectPath.indexOf('\\') >= 0)
    return false;
  foreach (part; objectPath.split("/")) {
    if (part == "..")
      return false;
  }
  return true;
}

/// 由 BlobConfig.buckets 构建 Bucket 映射（按 `name` 索引）。
void loadBucketsFromConfig(const(BlobConfig) config, BlobRepo repo) {
  foreach (bc; config.buckets) {
    if (bc.name.length == 0) {
      logInfo("Skip bucket with empty name");
      continue;
    }
    repo.buckets[bc.name] = bc;
  }
  logInfo("Loaded %s blob buckets from config", config.buckets.length.to!string);
}

/// 多桶 Blob 仓库：物理路径 `base`/`bucket.name`/objectPath。
class BlobRepo {
  const string base;

  bool[string] images;

  ulong maxSize = 100 * 1024 * 1024;

  Bucket[string] buckets;

  this(const(BlobConfig) config) {
    this.base = config.base;
    this.maxSize = config.maxSize;
    mkdirRecurse(expandTilde(config.base));
    loadBucketsFromConfig(config, this);
    this.images[".jpg"] = true;
    this.images[".png"] = true;
    this.images[".gif"] = true;
    this.images[".jpeg"] = true;
    this.images[".webp"] = true;
    this.images[".svg"] = true;
    this.images[".ico"] = true;
    this.images[".bmp"] = true;
    this.images[".tiff"] = true;
    this.images[".tif"] = true;
  }

  /** 按 path 风格解析：endpoint 之后路径的首段为桶名，其余为对象路径（见 `blobPathSplitBucket`）。 */
  BlobResolve resolveBlob(string uriAfterEndpoint) const {
    string u = uriAfterEndpoint;
    if (u.length == 0)
      u = "/";
    else if (!u.startsWith("/"))
      u = "/" ~ u;

    string bucketKey;
    string objPath;
    if (!blobPathSplitBucket(u, bucketKey, objPath))
      return BlobResolve(Bucket.init, "/");

    auto p = bucketKey in buckets;
    Bucket b = p !is null ? *p : Bucket.init;
    return BlobResolve(b, objPath);
  }

  string toPhysicalPath(const Bucket bucket, string objectPath) const {
    if (bucket.name.length == 0)
      return "";
    if (!isSafeBlobObjectPath(objectPath))
      return "";
    if (!objectPath.startsWith("/"))
      objectPath = "/" ~ objectPath;
    return expandTilde(base) ~ "/" ~ bucket.name ~ objectPath;
  }

  int check(const Bucket bucket, string objectPath) const {
    if (bucket.name.length == 0)
      return 0;
    assert(objectPath.startsWith("/"), "objectPath must start with /");
    if (!isSafeBlobObjectPath(objectPath))
      return 0;
    auto fullPath = toPhysicalPath(bucket, objectPath);
    if (fullPath.length == 0)
      return 0;
    if (exists(fullPath)) {
      return isDir(fullPath) ? 1 : 2;
    }
    return 0;
  }

  public string getRealname(const Bucket bucket, string objectPath) {
    auto fullPath = toPhysicalPath(bucket, objectPath);
    if (fullPath.length == 0)
      return "";
    if (!exists(fullPath) || isDir(fullPath))
      return "";
    return getUserXattr(fullPath, "original_name");
  }

  public BlobMeta create(const Bucket bucket, string tmpfile,
      string filename, string dir, string owner) {
    assert(bucket.name.length > 0 && dir.startsWith("/"), "bucket and dir must be valid");
    enforce(isSafeBlobObjectPath(dir), "invalid blob object path");

    BlobMeta meta;

    auto tmp = File(tmpfile);
    auto shaHex = toHexString!(LetterCase.lower)(digest!SHA1(tmp.byChunk(4096 * 1024))).idup;
    meta.name = filename;
    meta.fileSize = tmp.size();
    meta.mediaType = getMimeTypeForFile(filename);
    meta.sha = shaHex;
    import std.path;

    auto ext = extension(meta.name);
    string filePath;
    if (dir.endsWith("/")) {
      filePath = dir ~ shaHex ~ ext;
    } else {
      filePath = dir ~ "/" ~ shaHex ~ ext;
    }
    meta.filePath = filePath;
    auto physicalPath = toPhysicalPath(bucket, filePath);
    enforce(physicalPath.length > 0, "invalid blob object path");
    mkdirRecurse(dirName(physicalPath));

    copy(tmpfile, physicalPath);
    setBlobUserMeta(physicalPath, owner, shaHex, filename);
    meta.updatedAt = timeLastModified(physicalPath);

    return meta;
  }

  public bool remove(const Bucket bucket, string objectPath) {
    if (bucket.name.length == 0 || !objectPath.startsWith("/") || !isSafeBlobObjectPath(objectPath))
      return false;
    auto fullPath = toPhysicalPath(bucket, objectPath);
    if (fullPath.length == 0)
      return false;
    if (std.file.exists(fullPath)) {
      std.file.remove(fullPath);
      return true;
    }
    return false;
  }
}
