# micdn HTTP 压测基线报告（2026-08-13）

目的：为「给定规范化 uri 快速判断 base 下是否存在对应文件」的优化讨论提供基线，重点压**最坏路径**（目录 → `index.html`，一次请求累计 5 次 stat）。

---

## 环境与构建

| 项目 | 值 |
|------|-----|
| 机器 | Linux fc44 x86_64，AMD Ryzen 7 7735HS（8C16T），59G 内存 |
| 构建 | `dub build --build=release-nobounds --compiler=ldc2`，micdn 0.3.0 |
| 被测 commit | `490a455`（develop） |
| 压测工具 | ApacheBench 2.3（`ab -k -r`，`scripts/stress_http.sh` 包装） |
| 被测配置 | `listen=127.0.0.1:8899`，单个 www doc `manual`（zip 部署，`try-file=index.html`） |
| 样例文件 | `app.js` 138KB、`app.css` 44KB、`vendor.css` 14KB、`index.html` 174B、`docs/guide.html` |
| 测量方法 | 各场景预热 5 次后，3 轮各 10000 请求，取中位数 |

## 场景与预期 stat 次数

| 场景 | URL | `WwwRepo.get` | `sendFileImpl` | 合计 |
|------|-----|--------------|----------------|------|
| 目录 → index.html（**最坏路径**） | `/manual/` | 3 次同步 stat（`exists`+`isDir`+`exists(index.html)`） | 2 次异步 stat（`existsFile`+`getFileInfo`） | **5 次** |
| 文件命中 | `/manual/app.js` | 1 次 | 2 次 | 3 次 |
| 404 未命中 | `/manual/nope.js` | 1 次（`exists` 失败即返回） | — | 1 次 |

## 结果（并发 100 × 10000 请求）

| 场景 | RPS | 平均延迟(ms) | P99(ms) | 失败 | 备注 |
|------|-----|-------------|---------|------|------|
| `/manual/` 最坏路径 | **19 991** | 5.00 | 8 | 0 | keep-alive，全 200 |
| `/manual/app.js` 文件命中 | **10 278** | 9.73 | 14 | 0 | 约 1.3 GB/s，带宽/IO 为主 |
| `/manual/nope.js` 404 | **13 626** | 7.34 | 10 | 0 | 不带 keep-alive（原因见下） |
| `/manual/app.js` gzip 命中 | **16 736** | 5.97 | 9 | 0 | keep-alive，`Content-Length: 11392` |

### 说明与发现

1. **最坏路径（5 次 stat）仍有约 2 万 RPS**，P99 8ms、0 失败。单机静态服务下 stat 不是当前瓶颈；stat 合并（一次 `getFileInfo` 替代 `exists`+`isDir`+`exists`）的收益主要体现在：去掉 event loop 上的 3 次同步 `std.file` 调用（避免阻塞事件循环）、以及消除 `get()` 与 `sendFileImpl` 对同一文件的重复 stat（在该量级下收益有限，主要面向更高并发/更深目录的部署）。
2. **404 测量需关闭 keep-alive**：`ab -k` 对非 2xx 响应会计为 Length 失败并断开连接，数字虚高（实测 `/manual/nope.js` keep-alive 下报 24 321 RPS 但 6 705 failed、Non-2xx 5 000）。因此 404 场景用不带 `-k` 的命令重测，上述数字可信。
3. **同机测量波动**：预热后 3 轮波动收窄——最坏路径 16.0k–20.7k、文件命中 10.1k–11.0k、404 13.5k–13.9k、gzip 16.5k–17.4k（首轮普遍偏低，机器预热/CPU 频率爬升所致）。结论：5 次 stat 下单机约 2 万 RPS 量级；后续对比建议按同样「预热 + 多轮取中位」方法执行。

## 复现

完整复现步骤（构建、样例准备、启动、四场景命令与结果记录模板）见 [docs/stress_test.md](./stress_test.md)。
