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

module micdn.web.curl;
/// 下载工具，通过 dub 编译开关切换实现：
/// - 默认（`dub build`）：调用宿主 `curl` 命令，宿主需安装 curl
/// - `dub build -c executable-static`（`version(MicdnUseLibcurl)`）：静态链接 libcurl，不依赖宿主 curl/openssl

import std.datetime.stopwatch : StopWatch, AutoStart;
import std.file, std.path;
import vibe.core.log;

/**
 * Fetch url and store at local.
 * Downloads to a temp file in the same directory as target first (avoiding cross-device
 * rename), then renames on success. No target directory is created when download fails.
 *
 * 每次调用在 micdn 日志中固定打一条：成功 `Downloaded …`，失败 `Download failed …`。
 */
bool curlDownload(string url, string local) {
  mkdirRecurse(dirName(local));
  auto tmpPath = dirName(local) ~ "/." ~ baseName(local) ~ ".part";
  scope (exit) {
    if (exists(tmpPath))
      remove(tmpPath);
  }

  auto sw = StopWatch(AutoStart.yes);
  bool ok;

  version (MicdnUseLibcurl) {
    ok = libcurlDownload(url, tmpPath);
  } else {
    import std.process : execute;
    import std.string : strip;
    auto cmd = execute(["curl", "--fail", "--silent", "--show-error", "-L",
        "--connect-timeout", "10",
        "--max-time", "300",
        "--speed-time", "30",
        "--speed-limit", "1024",
        "-o", tmpPath, url]);
    if (cmd.status != 0) {
      auto detail = cmd.output.strip();
      if (detail.length)
        logWarn("Download failed %s -> %s (curl exit %s): %s", url, local, cmd.status, detail);
      else
        logWarn("Download failed %s -> %s (curl exit %s)", url, local, cmd.status);
      return false;
    }
    ok = true;
  }

  if (!ok || !exists(tmpPath)) {
    if (ok)
      logWarn("Download failed %s -> %s: temp file missing after download", url, local);
    return false;
  }
  rename(tmpPath, local);
  logInfo("Downloaded %s -> %s (%s bytes, %.1fs)", url, local, getSize(local),
      sw.peek.total!"seconds");
  return true;
}

version (MicdnUseLibcurl) {
  private bool libcurlDownload(string url, string tmpPath) {
    import std.conv : to;
    import std.stdio : File;
    import std.string : toStringz;

    import etc.c.curl;

    auto gcode = curl_global_init(CurlGlobal.all);
    if (gcode != 0) {
      logWarn("Download failed: curl_global_init: %s", curl_easy_strerror(gcode).to!string);
      return false;
    }
    scope (exit) curl_global_cleanup();

    auto h = curl_easy_init();
    if (h is null) {
      logWarn("Download failed: curl_easy_init returned null");
      return false;
    }
    scope (exit) curl_easy_cleanup(h);

    File f;
    try {
      f.open(tmpPath, "wb");
    } catch (Exception e) {
      logWarn("Download failed %s -> %s: %s", url, tmpPath, e.msg);
      return false;
    }
    scope (exit) f.close();

    curl_easy_setopt(h, CurlOption.url, url.toStringz);
    curl_easy_setopt(h, CurlOption.failonerror, 1L);
    curl_easy_setopt(h, CurlOption.followlocation, 1L);
    curl_easy_setopt(h, CurlOption.maxredirs, 10L);
    curl_easy_setopt(h, CurlOption.connecttimeout_ms, 10_000L);
    curl_easy_setopt(h, CurlOption.timeout_ms, 300_000L);
    curl_easy_setopt(h, CurlOption.low_speed_time, 30L);
    curl_easy_setopt(h, CurlOption.low_speed_limit, 1024L);
    curl_easy_setopt(h, CurlOption.noprogress, 1L);
    curl_easy_setopt(h, CurlOption.writefunction, &curlWriteCb);
    curl_easy_setopt(h, CurlOption.writedata, &f);

    auto rc = curl_easy_perform(h);
    if (rc != 0) {
      logWarn("Download failed %s (curl %s)", url, curl_easy_strerror(rc).to!string);
      return false;
    }
    return true;
  }

  extern(C) size_t curlWriteCb(char* ptr, size_t size, size_t nitems, void* userdata) {
    import std.stdio : File;
    auto f = cast(File*) userdata;
    f.rawWrite((cast(ubyte*) ptr)[0 .. size * nitems]);
    return size * nitems;
  }
}
