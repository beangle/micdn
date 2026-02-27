module micdn.web.filebrowser;
/// 生成目录浏览列表的辅助逻辑，用于展示文件与子目录。

import std.algorithm;
import std.array : appender;
import std.conv;
import std.datetime.date;
import std.file;
import std.string;

auto list(string path) {
  auto startIdx = path.length;
  if (!path.endsWith("/")) {
    startIdx += 1;
  }
  int size = 0;
  foreach (DirEntry entry; dirEntries(path, SpanMode.shallow)) {
    size++;
  }
  FileEntry[] entries = new FileEntry[size];
  int i = 0;
  foreach (DirEntry entry; dirEntries(path, SpanMode.shallow)) {
    FileEntry fe = new FileEntry();
    fe.name = entry.name[startIdx .. $];
    fe.isDir = entry.isDir();
    fe.size = entry.size();
    auto st = entry.timeLastModified;
    fe.lastModified = DateTime(st.year, st.month, st.day, st.hour, st.minute, st.second);
    entries[i++] = fe;
  }
  sort(entries);
  return entries;
}

auto genListContents(string dir, string prefix, string uri) {
  auto entries = list(dir);
  auto app = appender!string();
  auto lastSlash = uri[0 .. $ - 1].lastIndexOf("/");
  if (lastSlash > -1) {
    app.put("<a href=\"");
    app.put(prefix);
    app.put(uri[0 .. lastSlash + 1]);
    app.put("\">..</a>\n");
  }
  foreach (entry; entries) {
    app.put(entry.toLine());
    app.put("\n");
  }
  return app.data;
}

class FileEntry {
  string name;
  bool isDir;
  DateTime lastModified;
  ulong size;

  auto toLine() {
    auto buf = appender!string();
    buf.put("<a href=\"");
    buf.put(name);
    if (isDir) {
      buf.put("/");
    }
    buf.put("\" >");
    buf.put(name);
    if (isDir) {
      buf.put("/");
    }
    buf.put("</a>");
    auto href = buf.data;
    ulong padding = 0;
    if (name.length < 60) {
      padding = (60 - name.length) + href.length;
    }
    if (isDir) {
      return leftJustify(href, padding, ' ') ~ lastModified.toString() ~ rightJustify("-", 30, ' ');
    } else {
      return leftJustify(href, padding, ' ') ~ lastModified.toString() ~ rightJustify(size.to!string,
          30, ' ');
    }
  }

  public override int opCmp(Object o) {
    return cmp(this.name, (cast(FileEntry) o).name);
  }
}

@("web filebrowser sort entries")
unittest {
  auto entries = new FileEntry[2];
  entries[0] = new FileEntry();
  entries[1] = new FileEntry();
  entries[0].name = "av";
  entries[1].name = "a";
  sort(entries);
  assert(entries[0].name == "a");
}
