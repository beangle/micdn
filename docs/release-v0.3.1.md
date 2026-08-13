# Micdn v0.3.1 Release Notes

**发布日期：** 2026-08-14  
**对比基线：** [v0.3.0](https://github.com/beangle/micdn/compare/v0.3.0...v0.3.1)

---

## 概要

v0.3.1 是维护性小版本，主题是「更省内存、更稳定」。

- **更省内存**：文件响应改为 `FileStream` 流式写出（不再整文件读入 GC 堆）；内置主动回收 `runGcMinimize`（启动期重活后回收一次 + 每 20 分钟周期回收，glibc `malloc_trim` 经 dlsym 探测、musl 下自动跳过）；GC `maxPoolSize` 调至 4M（实测各阶段 RSS 比 8M 低 5–8MB，吞吐无回退）；新增 `/admin/reclaim` 按需回收端点。
- **更稳定**：修复 `version (Linux)` 守卫（实际为 `version (linux)`），inotify watch、www auto-deploy、SIGHUP reload 在 Linux 真正编译启用；SIGHUP 改经 eventcore 跨线程事件派发，不再因任务落在不消费队列的线程而失效；`clean` 后重启不再为自建空目录输出 `Removing` 噪音日志。
- **工程**：压测脚本化——`scripts/stress_bench.sh`（四场景吞吐）与 `scripts/stress_mem.sh`（多文件内存，可选 `/admin/reclaim`），移除旧 `scripts/stress_http.sh`；固化了历次压测踩坑（ab URL 最后传参、awk 解析、404 不带 `-k`、记录 CPU 频率与 load）。

无 Breaking Change，`micdn.xml` 配置无需调整。

---

## 版本评价

### 更省内存

- 流式响应：`sendFile` 走 `FileStream` pipe（`maxWholeFileMemSend = 0`），大文件不再整读入 GC 堆，降低堆峰值与分配抖动；gzip 预压缩 sidecar 走 `writeRawBody` 原始写通道，避免 `Content-Encoding: gzip` 下的二次压缩。
- 主动回收：启动期重活（www 索引构建、gzip 预压缩）完成后立即回收一次，让 RSS 回到日常水平；之后每 20 分钟周期回收；`runGcMinimize` 统一为 `GC.collect` + minimize + glibc `malloc_trim`（dlsym 运行时探测，musl/Alpine 镜像无此符号时自动跳过）。
- GC `maxPoolSize` 4M：与 8M 同日 A/B 对比，RSS 各阶段低 5–8MB，四场景吞吐无回退（详见「性能数据」）。
- `/admin/reclaim`：按需手动回收（仅 localhost），返回回收前后 RSS/HWM、GC used/free 与 `mallocTrim` 布尔值，便于观察"内存是否真的还给了 OS"。

### 更稳定

- Linux 专属功能真正生效：`version (Linux)` 在 Linux 上永不匹配，改为 `version (linux)` 后 inotify 目录监听、www auto-deploy、SIGHUP reload 才真正编译启用。
- SIGHUP reload 修复：信号线程直接 `runTask` 不执行（任务落在不 drain 队列的线程），改为经 eventcore 跨线程事件投递到事件循环执行；inotify 单测一并激活。
- `clean` 日志修复：部署可写性探测不再创建目标目录（缺失时探测父链可写性），`clean` 后重启不再为自建空目录输出 `Removing`。

### 更一致

- 内存回收语义集中到 `micdn.runtime`：metrics 保持只读指标，内存快照由 runtime 提供，回收行为单一入口。
- 压测口径脚本化：吞吐与内存两个脚本固化复测方法（预热轮数、取中位数、频率/load 记录），跨版本对比不再依赖手工命令。

---

## 性能数据

同日 A/B（`c100 × 10000`，预热 5 轮 + 3 轮取中位，失败 0；AMD Ryzen 7 7735HS，`performance` 调速器）：

| 场景 | 4M | 8M |
|------|-----|-----|
| 目录 `/manual/` | 37.2k | 37.2k |
| 文件命中 `app.js` | 14.3k | 13.2k |
| 404 `nope.js` | 15.3k | 15.1k |
| gzip 命中 `app.js` | 34.0k | 32.7k |

内存（多文件样例 2000 small + 150 medium + 24 big，RSS）：

| 阶段 | 4M | 8M |
|------|-----|-----|
| 启动后 | 19.6MB | 23.6MB |
| c50 多路径 | 29.3MB | 35.9MB |
| heavy c200 | 30.5MB | 38.9MB |
| `/admin/reclaim` 后 | 27.5MB | 35.9MB |

结论：4M 池在吞吐不变的前提下，把运行 RSS 全面压低 5–8MB；启动后 RSS 19.6MB，达到 20MB 以内目标。回收端点在 heavy 后可收回约 3MB（GC 空闲堆仍有部分未还给 OS，符合 glibc 分段内存特性）。

---

## 升级注意

- **无 Breaking**：配置、CLI、HTTP 接口均兼容 v0.3.0。
- 内置 GC 参数为 `gcopt=maxPoolSize:4M heapSizeFactor:1.2`，与 v0.2.x/v0.3.0 自带的 8M 相比运行 RSS 更低。
- `/admin/reclaim` 仅接受 localhost 回环来源（与 `/admin/metrics` 同档）。
- `clean` 后重启的日志行为变化：不再出现针对自建空目录的 `Removing` 记录。

---

## 提交统计

v0.3.1 相对 v0.3.0：3 个提交（`adb9b73` 流式响应与内存回收 / `cddadda` Linux 守卫与 SIGHUP 修复 / `92bc269` clean 日志修复）+ 本轮维护（4M 池调参、`/admin/reclaim`、压测脚本整理、版本与文档）。
