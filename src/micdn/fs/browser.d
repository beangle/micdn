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

module micdn.fs.browser;
/// 生成目录浏览列表的辅助逻辑，用于展示文件与子目录。

import std.algorithm;
import std.array;
import std.conv;
import std.datetime.date;
import std.file;
import std.format;
import std.string;

/// 单条列表项的结构化数据，供模板渲染使用。
struct ListEntry {
  string name; /// 显示名称（如 ".."、"dirname/"、"file.txt"）
  string href; /// 链接地址（相对路径）
  bool isDir; /// 是否为目录
  string iconKey; /// 图标键，用于从 fileIcons 中查找 emoji（如 "dir"、"js"、"default"）
  string lastModified; /// 最后修改时间（已格式化）
  string size; /// 大小显示（目录为 "-"，文件为字节数）
}

/// 文件列表的结构化数据，供模板渲染使用。
struct FileListData {
  string uri; /// 当前路径（用于标题）
  ListEntry[] entries; /// 列表项（含父目录 ".." 及当前目录下的条目）
  string[string] fileIcons; /// 图标键 -> emoji 的映射，供前端按 iconKey 获取图标
}

class FileEntry {
  string name;
  bool isDir;
  DateTime lastModified;
  ulong size;

  public override int opCmp(Object o) {
    return cmp(this.name, (cast(FileEntry) o).name);
  }
}

/** 根据目录路径生成结构化文件列表数据，供模板渲染使用。
    Params:
        dir    = 本地目录的物理路径
        prefix = 未使用（保留以兼容旧调用方）
        uri    = 当前 URI 路径（如 /org/beangle/）
    Returns:
        FileListData，可直接传给 index.dt 模板
*/
/// 扩展名/类型 -> emoji 的图标映射，供前端显示使用。
enum fileIcons = [
  "dir" : "📁",
  "js" : "📜",
  "css" : "🎨",
  "img" : "🖼️",
  "zip" : "📦",
  "sha1" : "🔏",
  "xml" : "📋",
  "default" : "📄",
];

FileListData genListContents(string dir, string prefix, string uri) {
  auto rawEntries = list(dir);
  ListEntry[] entries;
  auto lastSlash = uri.length > 1 ? uri[0 .. $ - 1].lastIndexOf("/") : -1;
  if (lastSlash > -1) {
    entries ~= ListEntry("..", "..", true, "dir", "-", "-");
  }
  foreach (fe; rawEntries) {
    auto href = fe.isDir ? fe.name ~ "/" : fe.name;
    auto displayName = fe.isDir ? fe.name ~ "/" : fe.name;
    auto sizeStr = fe.isDir ? "-" : formatSize(fe.size);
    auto iconKey = iconKeyFor(fe.name, fe.isDir);
    entries ~= ListEntry(displayName, href, fe.isDir, iconKey, fe.lastModified.toString, sizeStr);
  }
  return FileListData(uri, entries, fileIcons);
}

/// 将字节数格式化为可读形式：如 "1.2 KB"、"345 MB"。
private string formatSize(ulong bytes) {
  if (bytes < 1024)
    return bytes.to!string ~ " B";
  if (bytes < 1024 * 1024)
    return format("%.1f KB", bytes / 1024.0);
  if (bytes < 1024UL * 1024 * 1024)
    return format("%.1f MB", bytes / (1024.0 * 1024));
  return format("%.1f GB", bytes / (1024.0 * 1024 * 1024));
}

/// 按扩展名返回图标键（对应 fileIcons 的 key）：dir/js/css/img/zip/sha1/xml/default
private string iconKeyFor(string name, bool isDir) {
  if (isDir)
    return "dir";
  auto dot = name.lastIndexOf('.');
  if (dot < 0)
    return "default";
  auto ext = name[dot + 1 .. $].toLower;
  if (ext == "js")
    return "js";
  if (ext == "css")
    return "css";
  if (ext == "png" || ext == "jpg" || ext == "jpeg" || ext == "gif")
    return "img";
  if (ext == "zip" || ext == "jar" || ext == "war")
    return "zip";
  if (ext == "sha1")
    return "sha1";
  if (ext == "xml" || ext == "pom")
    return "xml";
  return "default";
}

private auto list(string path) {
  auto startIdx = path.length;
  if (!path.endsWith("/")) {
    startIdx += 1;
  }
  FileEntry[] result;
  foreach (DirEntry entry; dirEntries(path, SpanMode.shallow)) {
    auto fe = new FileEntry();
    fe.name = entry.name[startIdx .. $];
    fe.isDir = entry.isDir();
    fe.size = entry.size();
    auto st = entry.timeLastModified;
    fe.lastModified = DateTime(st.year, st.month, st.day, st.hour, st.minute, st.second);
    result ~= fe;
  }
  sort(result);
  return result;
}
