/* Copyright (C) 2026 Beangle
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

module micdn.gzip;
/// gzip 预压缩 sidecar：请求侧资格判断与后台压缩队列。
///
/// 设计约定：
/// - 请求线程只读 `path.gz`，存在即由 `web.file.sendFile` 直接发送；不存在且 `favorGzip` 时由 `sendFile` 入队，仍按源文件服务。
/// - 压缩只发生在后台 worker 线程（单消费者），写 `tmp` 后原子 `rename`，无文件写竞争。
/// - asset 的 `<dir>` 符号链接挂载完全忽略 gzip（不发送已有 `.gz` 也不生成），由调用方以 `favorGzip=false` 排除。

import std.conv : to;
import std.exception;
import std.file;
import std.path;
import std.string;
import std.uni : toLower;
import std.zlib : Compress, HeaderFormat;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;

import vibe.http.server : HTTPServerRequest;

/// 后台压缩队列容量上限；满则丢弃入队（去重集合保证同一路径只入队一次，丢弃不损失待压路径）。
enum size_t maxPendingGzip = 8192;
/// 单个文件超过该大小不压缩（避免大内存分配），与 `web.file` 内存发送阈值一致。
enum size_t maxGzipFileSize = 8u * 1024 * 1024;
/// 压缩级别：后台线程执行，用最高级别。
enum int gzipCompressionLevel = 9;

/// 可压缩的文本类扩展名（小写、含前导 `.`）。已压缩格式（`.gz`/`.br`/图片/字体等）不在白名单。
immutable string[] gzipExtensionList = [
    ".js", ".mjs", ".cjs", ".css", ".html", ".htm", ".svg",
    ".json", ".map", ".xml", ".txt", ".md", ".webmanifest",
];

/// 扩展名 O(1) 查询。
immutable bool[string] gzipExtensions;

shared static this() {
  bool[string] set;
  foreach (ext; gzipExtensionList)
    set[ext] = true;
  gzipExtensions = cast(immutable) set;

  queueMutex = new Mutex();
  queueCond = new Condition(queueMutex);
}

/** 文件是否适合 gzip（扩展名在白名单内，且不是符号链接由调用方保证）。 */
bool isGzipEligible(string path) @safe pure {
  auto ext = std.path.extension(std.path.baseName(path)).toLower();
  return (ext in gzipExtensions) !is null;
}

/** 请求头 `Accept-Encoding` 是否接受 gzip。

    支持 `gzip`、`*` 通配与 `q=0` 语义；显式 `gzip;q=0` 优先于 `*` 生效。
    未携带 `Accept-Encoding` 时不视为接受 gzip。
*/
bool acceptsGzip(scope HTTPServerRequest req) @safe {
  auto ae = "Accept-Encoding" in req.headers;
  if (ae is null)
    return false;
  bool wildcard;
  foreach (part; (*ae).split(',')) {
    auto token = part.strip();
    if (token.length == 0)
      continue;
    auto semi = token.indexOf(';');
    auto name = (semi < 0 ? token : token[0 .. semi]).strip().toLower();
    double q = 1.0;
    if (semi >= 0) {
      foreach (param; token[semi + 1 .. $].split(';')) {
        auto eq = param.indexOf('=');
        if (eq > 0 && param[0 .. eq].strip().toLower() == "q") {
          try
            q = param[eq + 1 .. $].strip().to!double;
          catch (Exception)
            q = 0.0;
          break;
        }
      }
    }
    if (name == "gzip")
      return q > 0;
    if (name == "*" && q > 0)
      wildcard = true;
  }
  return wildcard;
}

/** 将单个文件压缩为 `path.gz`（tmp + rename 原子落盘）。

    仅当压缩后确实更小才生成；文件不存在、过大、已是符号链接或不可压缩时返回 false。
    sidecar 已存在时视为成功（幂等，供队列去重后的重复处理使用）。
*/
bool gzipFile(string path) {
  if (!exists(path) || isDir(path) || isSymlink(path))
    return false;
  if (!isGzipEligible(path))
    return false;
  auto size = getSize(path);
  if (size == 0 || size > maxGzipFileSize)
    return false;
  auto gzPath = path ~ ".gz";
  if (exists(gzPath))
    return true;

  auto data = read(path);
  auto comp = new Compress(gzipCompressionLevel, HeaderFormat.gzip);
  ubyte[] gzData;
  gzData ~= cast(ubyte[]) comp.compress(data);
  gzData ~= cast(ubyte[]) comp.flush();
  if (gzData.length >= data.length)
    return false;

  auto tmpPath = gzPath ~ ".tmp";
  scope (failure) {
    if (exists(tmpPath))
      remove(tmpPath);
  }
  std.file.write(tmpPath, gzData);
  rename(tmpPath, gzPath);
  return true;
}

// --- 后台压缩队列：单 worker 线程，Mutex + Condition，去重 ---

private __gshared Mutex queueMutex;
private __gshared Condition queueCond;
private __gshared Thread workerThread;
private __gshared bool workerStopped;
private __gshared string[] pending;
private __gshared bool[string] queued;

/** 请求线程调用：将待压缩文件路径入队（去重）；worker 未启动则惰性启动。 */
void enqueueGzip(string path) {
  queueMutex.lock();
  scope (exit) queueMutex.unlock();
  if (workerStopped || (path in queued) !is null || pending.length >= maxPendingGzip)
    return;
  queued[path] = true;
  pending ~= path;
  if (workerThread is null) {
    workerThread = new Thread(&workerMain);
    workerThread.isDaemon = true;
    workerThread.start();
  }
  queueCond.notify();
}

private void workerMain() {
  while (true) {
    queueMutex.lock();
    while (pending.length == 0 && !workerStopped)
      queueCond.wait();
    if (pending.length == 0 && workerStopped) {
      queueMutex.unlock();
      break;
    }
    auto path = pending[$ - 1];
    pending.length--;
    queued.remove(path);
    queueMutex.unlock();

    gzipFile(path);
  }
}

/** 停止并等待后台压缩线程退出（进程退出前调用；未启动过则空操作）。
    停止后允许再次 `enqueueGzip` 惰性重启新 worker，便于测试复用。 */
void stopGzipWorker() {
  queueMutex.lock();
  workerStopped = true;
  queueCond.notifyAll();
  queueMutex.unlock();
  if (workerThread !is null) {
    workerThread.join();
    workerThread = null;
  }
  queueMutex.lock();
  workerStopped = false;
  queueMutex.unlock();
}
