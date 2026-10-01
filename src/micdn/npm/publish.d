/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.npm.publish;
/** npm publish 协议的服务端最小子集：把 `PUT /npm/{pkg}` 的请求体（packument + `_attachments`）
    解出 tgz 并装入本地仓库（`installTarball`）。

    只处理 `npm publish` 实际会发的形状：`versions` 只含本次发布的一个版本，
    `_attachments` 只有一项、其 `data` 是 tgz 的 Base64。落盘与元数据生成全部复用
    `installTarball` —— 包名/版本取自 tarball 内的 `package/package.json`，`dist-tags`
    沿用同一套规则（`latest` + 通道 tag，`--tag` 指定的自定义 tag 作为 `extraTag`）。

    HTTP 侧（`NpmService`）负责令牌校验与 body 读取；本模块不碰请求/响应，
    便于单测。协议细节见 https://github.com/npm/registry/blob/master/docs/REGISTRY-API.md
*/

import std.algorithm.searching : canFind;
import std.file;
import std.json;
import std.path;
import std.string;
import std.uuid : randomUUID;

import micdn.npm.packument : InstallResult, channelOf, installTarball, prereleaseChannels;
import micdn.web.publish : decodeBase64Loose;

/** 解析 `npm publish` 请求体并安装，返回 `installTarball` 的结果。

    `expectedName` 是 URI 路径上的包名（含 scope，如 `@xurp/manual`）；非空时要求与请求体
    的 `name` 一致，防止把 A 包的 tarball 发到 B 包的路径。`registryBase` 通常是
    `{origin}/npm`（写占位符，交付期替换）。
*/
InstallResult installPublishedPackument(string base, string expectedName,
    const(ubyte)[] body, string registryBase) {
  JSONValue doc;
  try
    doc = parseJSON(cast(string) body);
  catch (Exception e)
    throw new Exception("invalid npm publish body: " ~ e.msg);
  if (doc.type != JSONType.object)
    throw new Exception("npm publish body must be a JSON object");

  auto name = jsonString(doc, "name");
  if (name.length == 0)
    throw new Exception("npm publish body lacks name");
  if (expectedName.length > 0 && name != expectedName)
    throw new Exception("npm publish name " ~ name ~ " does not match path " ~ expectedName);

  auto attachment = singleAttachment(doc);
  if (attachment.type != JSONType.object)
    throw new Exception("npm publish body needs exactly one _attachments entry");
  auto encoded = jsonString(attachment, "data");
  if (encoded.length == 0)
    throw new Exception("npm publish attachment has no data");

  ubyte[] tgz;
  try
    tgz = decodeBase64Loose(encoded);
  catch (Exception e)
    throw new Exception("npm publish attachment is not valid base64: " ~ e.msg);
  auto tmp = buildPath(tempDir(), "micdn-publish-" ~ randomUUID().toString() ~ ".tgz");
  scope (exit)
    if (exists(tmp))
      std.file.remove(tmp);
  std.file.write(tmp, tgz);

  // 版本用于把 dist-tags 里的自定义 tag 挂到本次发布上（latest 与通道 tag 由 refreshPackument 推导）
  auto ver = firstKey(doc, "versions");
  return installTarball(base, tmp, registryBase, customTag(doc, ver));
}

/// 取唯一的 `_attachments` 条目；不是「恰好一项」时返回 null 值（type 为 null）。
private JSONValue singleAttachment(JSONValue doc) {
  if (auto a = "_attachments" in doc.object)
    if (a.type == JSONType.object && a.object.length == 1)
      foreach (key, value; a.object)
        return value;
  return JSONValue.init;
}

/// `versions` 的第一个（也是唯一一个）版本号；没有则空串。
private string firstKey(JSONValue doc, string field) {
  if (auto v = field in doc.object)
    if (v.type == JSONType.object && v.object.length >= 1)
      foreach (key, value; v.object)
        return key;
  return "";
}

/** `dist-tags` 里指向本次版本的自定义 tag，交给 `installTarball` 的 `extraTag`。

    `latest` 与「本次版本自身所属通道」的 tag 交由 `refreshPackument` 推导：后者取该通道内**最高**版本，
    直接下发会把 `dev`/`next` 等指回本次（可能更旧的）版本。其余 tag 原样保留——包括给正式版打的通道
    tag（如 `npm publish --tag dev` 发 2.0.0），否则本次发布的意图会被静默丢弃。
*/
private string customTag(JSONValue doc, string ver) {
  if (ver.length == 0)
    return "";
  if (auto tags = "dist-tags" in doc.object)
    if (tags.type == JSONType.object)
      foreach (tag, value; tags.object)
        if (value.type == JSONType.string && value.str == ver) {
          if (tag == "latest")
            continue;
          if (prereleaseChannels.canFind(tag) && tag == channelOf(ver))
            continue;
          return tag;
        }
  return "";
}

/// 对象里的字符串字段；缺失或非字符串返回空串。
private string jsonString(JSONValue doc, string field) {
  if (auto v = field in doc.object)
    if (v.type == JSONType.string)
      return v.str;
  return "";
}
