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

module micdn.prune;
/// 定时仓库清理：按 `<prune at="HH:MM" …/>` 在本机时区每天执行一次。
///
/// 没有 `<prune>` 时不调度，只保留手动 `micdn prune` / `/admin/prune`。定时器每次执行完
/// 重新计算下一次时刻（跨天/时区都由本机时钟决定），reload 时由新配置重建。

import std.conv : to;
import std.datetime : Clock, Date, DateTime, Duration, SysTime, TimeOfDay, dur;
import std.string : split;

import vibe.core.core : Timer, setTimer;
import vibe.core.log : logInfo, logWarn;

import micdn.maven.gc : pruneSnapshotBuilds;
import micdn.model : MicdnConfig;
import micdn.npm.packument : pruneDevVersions;

/// 按 `<prune>` 策略每天执行一次清理；`config.prune` 为 null 时禁用。
class PruneScheduler {
  /// 配置对象在构造时固定；reload 时由调用方 stop 旧的、new 一个并 start，避免读到半新半旧状态。
  private const MicdnConfig _config;
  private Timer _timer;

  this(const MicdnConfig config) {
    _config = config;
  }

  bool enabled() const {
    return _config.prune !is null;
  }

  void start() {
    if (!enabled())
      return;
    scheduleNext();
  }

  void stop() {
    // 默认 Timer 没有 driver 时 stop 是安全的空操作。
    _timer.stop();
  }

  private void scheduleNext() {
    auto delay = untilNext(_config.prune.at, Clock.currTime());
    logInfo("Micdn prune scheduled at %s (in %s)", _config.prune.at, delay);
    _timer = setTimer(delay, &run, false);
  }

  private void run() {
    // 单次定时器：执行完（无论成功失败）都重新排下一次；清理是本地 I/O，保持串行、不并发。
    try {
      auto npm = pruneDevVersions(_config.npm.base, _config.prune.npmDevKeep);
      auto maven = pruneSnapshotBuilds(_config.maven.base, _config.prune.mavenSnapshotKeep);
      logInfo("Micdn prune: npm %s versions/%s dirs, maven %s builds/%s files",
          npm.versionsRemoved, npm.dirsRemoved, maven.buildsRemoved, maven.filesRemoved);
    } catch (Exception e) {
      logWarn("Micdn prune failed: %s", e.msg);
    }
    scheduleNext();
  }
}

/// 到下一个 `HH:MM`（本机时区）的时长；`now` 已过当天时刻时取次日。
Duration untilNext(string at, SysTime now) {
  auto parts = at.split(":");
  auto hour = parts[0].to!int;
  auto minute = parts[1].to!int;
  auto date = Date(now.year, now.month, now.day);
  auto target = SysTime(DateTime(date, TimeOfDay(hour, minute)), now.timezone);
  if (target <= now) {
    auto tomorrow = (DateTime(date, TimeOfDay(0, 0)) + dur!"days"(1)).date;
    target = SysTime(DateTime(tomorrow, TimeOfDay(hour, minute)), now.timezone);
  }
  return target - now;
}
