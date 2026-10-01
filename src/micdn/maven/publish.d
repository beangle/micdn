/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.maven.publish;
/** 本地 maven 发布：把 `PUT /maven/{path}` 上传的构件原子写入本地仓库。

    服务端不解析、不重写上传内容——`mvn deploy` 自己生成时间戳文件名与
    `maven-metadata.xml`，原样落盘即可被 `/maven` 的读路径（含快照别名解析、
    artifact 级元数据合并）直接服务。与 npm 侧同口径：写入由令牌授权（见 `micdn.web.publish`），
    元数据由写入方产出。
*/

import std.algorithm.searching : any;
import std.file;
import std.path;
import std.string;

/// 上传写入仓库，返回落盘绝对路径；路径非法时抛异常。
string storeUpload(string base, string ruri, const(ubyte)[] body) {
  if (ruri.length == 0 || ruri == "/" || ruri.endsWith("/"))
    throw new Exception("maven publish requires a file path: " ~ ruri);
  // ruri 来自 repositoryUri(ResourceUri.segs)，已消解点段；这里再防一手直接调用方
  if (ruri.split("/").any!(seg => seg == ".." || seg == "."))
    throw new Exception("maven publish rejects dot segments: " ~ ruri);

  auto path = base ~ ruri;
  mkdirRecurse(dirName(path));
  // 与仓库其余写入一致（maven 元数据/上游下载）：先写 `.incoming` 临时文件，再同目录 rename 原子替换
  auto tmp = path ~ ".incoming";
  scope (failure)
    if (exists(tmp))
      remove(tmp);
  std.file.write(tmp, body);
  rename(tmp, path);
  return path;
}
