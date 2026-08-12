# micdn HTTP 压测对比报告（2026-08-13 复测）

目的：对比 commit `490a455`（基线）与 `8ddfd47`（`sendFile` 必填调用方预取的 `FileInfo`、www `get()` 改为异步 stat 并复用信息、gz 探测合并为单次 `getFileInfo`）对四场景的吞吐影响。

---

## 环境与构建

| 项目 | 值 |
|------|-----|
| 机器 | Linux fc44 x86_64，AMD Ryzen 7 7735HS（8C16T），59G 内存 |
| 构建 | `dub build --build=release-nobounds --compiler=ldc2`，micdn 0.3.0 |
| 被测 commit | 基线 `490a455`（develop）；复测 `8ddfd47`（develop） |
| 压测工具 | ApacheBench 2.3（`ab -k -r`，`scripts/stress_http.sh` 包装） |
| 被测配置 | `listen=127.0.0.1:8899`，单个 www doc `manual`（zip 部署，`try-file=index.html`） |
| 样例文件 | `app.js` 138KB、`app.css` 44KB、`vendor.css` 14KB、`index.html` 174B、`docs/guide.html` |
| 测量方法 | 各场景预热 5 轮后，3 轮各 10000 请求，取中位数；复测 load 0.53/0.40/0.40，CPU scaling 37% |

## 场景与预期 stat 次数（实现变化）

| 场景 | URL | 基线 `490a455` | 复测 `8ddfd47` |
|------|-----|---------------|---------------|
| 目录 → index.html（**最坏路径**） | `/manual/` | 5 次（get 3 同步 + sendFile 2 异步） | **2 次**（get 异步 location + index.html；sendFile 复用 FileInfo 为 0） |
| 文件命中 | `/manual/app.js` | 3 次 | **1 次**（get 异步；sendFile 0） |
| 404 未命中 | `/manual/nope.js` | 1 次（同步 `exists`） | 1 次（异步 `getFileInfo` 失败） |
| gzip 命中 | `/manual/app.js` | 3 次（源 2 + `existsFile(gz)`+`getFileInfo(gz)`） | **2 次**（get 源 1 + 单次 `getFileInfo(gz)`） |

## 结果（并发 100 × 10000 请求，预热 5 轮 + 3 轮取中位）

| 场景 | 基线 RPS | 复测 RPS | 变化 | 复测平均延迟(ms) | 复测 P99(ms) | 失败 |
|------|---------|---------|------|-----------------|-------------|------|
| `/manual/` 最坏路径 | 19 991 | **22 914** | **+14.6%** | 4.36 | 9 | 0 |
| `/manual/app.js` 文件命中 | 10 278 | **12 538** | **+22.0%** | 7.98 | 13 | 0 |
| `/manual/nope.js` 404 | 13 626 | **12 213** | **−10.4%** | 8.19 | 12 | 0 |
| `/manual/app.js` gzip 命中 | 16 736 | **20 950** | **+25.2%** | 4.77 | 9 | 0 |

复测各场景记录轮（round 6–8）：最坏路径 22.7k–24.3k、文件命中 12.3k–12.6k、404 12.0k–12.3k、gzip 20.9k–21.7k RPS。

## 分析

1. **stat 合并收益明显**：文件命中（3→1 次 stat）与 gzip 命中（3→2 次）分别提升 22% 与 25%；最坏路径（5→2 次）提升 15%。`WwwRepo.get` 将原先 3 次同步 `std.file` 调用换成 1–2 次 vibe 异步 `getFileInfo`，`sendFile` 复用 `FileInfo` 后不再自检，请求线程的 stat 与事件循环阻塞显著减少。
2. **404 单次 stat 场景回落约 10%**：该场景只有 1 次 stat 且无法复用（`getFileInfo` 失败即返回，`sendFile` 不会执行），异步 `getFileInfo`（经 IO worker 通道）相对同步 `exists` 多一次任务往返开销，属"去阻塞 + 复用 FileInfo"改动的固有边界——判断 404 必须 stat 确认文件缺失（`nope.js` 可能实际存在），无法短路；12k RPS 仍属同一量级，且不阻塞事件循环。
3. **同机波动说明**：复测期间 CPU scaling 37%、load < 0.6，与基线一致；按「预热 5 轮 + 3 轮取中位」执行，结论以中位数比较为准。

## 复现

完整复现步骤（构建、样例准备、启动、四场景命令与结果记录模板）见 [docs/stress_test.md](./stress_test.md)。
