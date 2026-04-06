/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.logging;
/// 固定行格式：`yyyy-MM-dd HH:mm:ss`、左对齐 5 列 level、` - `、消息。
/// 输出目标由 `log-file` 决定：`console` 为控制台，否则为文件（二者互斥）。

import std.file : mkdirRecurse;
import std.format : formattedWrite;
import std.path : dirName;
import std.stdio : File, stderr, stdout;
import std.string : leftJustify, rightJustify, strip, toLower;

import vibe.core.concurrency : lock;
import vibe.core.log;

/** 解析 log-level 属性；非法值抛 Exception。 */
LogLevel parseLogLevel(string s) {
  import std.exception : enforce;

  auto t = s.strip().toLower();
  enforce(t.length > 0, "log-level is empty");
  switch (t) {
  case "trace":
    return LogLevel.trace;
  case "debugv", "debug-v":
    return LogLevel.debugV;
  case "debug":
    return LogLevel.debug_;
  case "diagnostic", "verbose":
    return LogLevel.diagnostic;
  case "info":
    return LogLevel.info;
  case "warn", "warning":
    return LogLevel.warn;
  case "error":
    return LogLevel.error;
  case "critical":
    return LogLevel.critical;
  case "fatal":
    return LogLevel.fatal;
  default:
    throw new Exception("invalid log-level: " ~ s ~ " (expected trace|debug|info|warn|error|...)");
  }
}

private string levelWord(LogLevel l) {
  final switch (l) {
  case LogLevel.trace:
    return "TRACE";
  case LogLevel.debugV:
    return "DBGV";
  case LogLevel.debug_:
    return "DEBUG";
  case LogLevel.diagnostic:
    return "DIAG";
  case LogLevel.info:
    return "INFO";
  case LogLevel.warn:
    return "WARN";
  case LogLevel.error:
    return "ERROR";
  case LogLevel.critical:
    return "CRIT";
  case LogLevel.fatal:
    return "FATAL";
  case LogLevel.none:
    assert(false);
  }
}

private string padField(string s, int width, bool left) {
  if (width <= 0)
    return s;
  if (s.length > cast(size_t) width)
    return s[0 .. width];
  return left ? leftJustify(s, width) : rightJustify(s, width);
}

/** 固定前缀：`yyyy-MM-dd HH:mm:ss`、左对齐 5 列 level、` - `。 */
private void writeFixedLogPrefix(W)(ref W w, ref LogLine msg) {
  auto tm = msg.time;
  string lv = padField(levelWord(msg.level), 5, true);
  w.formattedWrite("%04d-%02d-%02d %02d:%02d:%02d %s - ", tm.year, cast(int) tm.month, tm.day, tm.hour,
      tm.minute, tm.second, lv);
}

/** 与 vibe `FileLogger` 相同的路由（info→info 流，其余→diag），行首为固定格式。 */
final class MicdnFixedLogger : Logger {
  private File m_infoFile;
  private File m_diagFile;
  private File m_curFile;

  this(File info_file, File diag_file) {
    m_infoFile = info_file;
    m_diagFile = diag_file;
  }

  this(string path) {
    auto f = File(path, "ab");
    this(f, f);
  }

  override void beginLine(ref LogLine msg) @trusted {
    final switch (msg.level) {
    case LogLevel.trace:
    case LogLevel.debugV:
    case LogLevel.debug_:
    case LogLevel.diagnostic:
    case LogLevel.warn:
    case LogLevel.error:
    case LogLevel.critical:
    case LogLevel.fatal:
      m_curFile = m_diagFile;
      break;
    case LogLevel.info:
      m_curFile = m_infoFile;
      break;
    case LogLevel.none:
      assert(false);
    }
    auto dst = m_curFile.lockingTextWriter;
    writeFixedLogPrefix(dst, msg);
  }

  override void put(scope const(char)[] text) @trusted {
    m_curFile.write(() @trusted { return text; } ());
  }

  override void endLine() @trusted {
    m_curFile.writeln();
    m_curFile.flush();
  }
}

/** 在 vibe 默认控制台 logger 已注册之后调用：关闭其输出，仅注册本项目的固定格式 logger（控制台或文件二选一）。 */
void applyMicdnLogging(string logFile, string logLevelStr) {
  import std.uni : icmp;

  LogLevel lv = parseLogLevel(logLevelStr);
  setLogLevel(LogLevel.none);

  shared(Logger) lg;
  if (icmp(logFile.strip(), "console") == 0) {
    lg = cast(shared) new MicdnFixedLogger(stdout, stderr);
  } else {
    auto parent = dirName(logFile);
    if (parent.length && parent != "." && parent != "/")
      mkdirRecurse(parent);
    lg = cast(shared) new MicdnFixedLogger(logFile);
  }
  {
    auto l = lock(lg);
    l.minLevel = lv;
  }
  registerLogger(lg);
}
