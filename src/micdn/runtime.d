/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.runtime;
/// 内置运行期调优：GC 池上限等（不可通过 micdn.xml 修改）。

import vibe.core.log;

enum gcMaxPoolSizeMb = 8;

extern (C) __gshared string[] rt_options = ["gcopt=maxPoolSize:8M heapSizeFactor:1.2"];

/** HTTP 服务启动时调用，记录内置 GC 配置（druntime 在 main 之前已读 rt_options）。 */
void applyRuntimeProfile() @safe nothrow {
  logInfo("Runtime profile: GC maxPoolSize=%sM heapSizeFactor=1.2", gcMaxPoolSizeMb);
}
