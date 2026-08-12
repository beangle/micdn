# micdn HTTP 压测基线报告（2026-08-13）

目的：为「给定规范化 uri 快速判断 base 下是否存在对应文件」的优化讨论提供基线，重点压**最坏路径**（目录 → `index.html`，一次请求累计 5 次 stat）。

---

## 环境与构建

| 项目 | 值 |
|------|-----|
| 机器 | Linux fc44 x86_64，AMD Ryzen 7 7735HS（8C16T），59G 内存 |
| 构建 | `dub build --build=release-nobounds --compiler=ldc2`，micdn 0.3.0 |
| 压测工具 | ApacheBench 2.3（`ab -k -r`，`scripts/stress_http.sh` 包装） |
| 被测配置 | `listen=127.0.0.1:8899`，单个 www doc `manual`（zip 部署，`try-file=index.html`） |
| 样例文件 | `app.js` 138KB、`app.css` 44KB、`vendor.css` 14KB、`index.html` 174B、`docs/guide.html` |

## 场景与预期 stat 次数

| 场景 | URL | `WwwRepo.get` | `sendFileImpl` | 合计 |
|------|-----|--------------|----------------|------|
| 目录 → index.html（**最坏路径**） | `/manual/` | 3 次同步 stat（`exists`+`isDir`+`exists(index.html)`） | 2 次异步 stat（`existsFile`+`getFileInfo`） | **5 次** |
| 文件命中 | `/manual/app.js` | 1 次 | 2 次 | 3 次 |
| 404 未命中 | `/manual/nope.js` | 1 次（`exists` 失败即返回） | — | 1 次 |

## 结果（并发 100 × 10000 请求）

| 场景 | RPS | 平均延迟(ms) | P99(ms) | 失败 | 备注 |
|------|-----|-------------|---------|------|------|
| `/manual/` 最坏路径 | **15 601** | 6.41 | 12 | 0 | keep-alive，全 200 |
| `/manual/app.js` 文件命中 | **9 140** | 10.94 | 18 | 0 | 约 1.2 GB/s，带宽/IO 为主 |
| `/manual/nope.js` 404 | **10 707** | 9.34 | 13 | 0 | 不带 keep-alive（原因见下） |
| `/manual/app.js` gzip 命中（修复后） | **11 378** | 8.79 | 17 | 0 | keep-alive，`Content-Length: 11392`，单次压缩 |

### 说明与发现

1. **最坏路径（5 次 stat）仍有 15.6k RPS**，P99 12ms、0 失败。单机静态服务下 stat 不是当前瓶颈；stat 合并（一次 `getFileInfo` 替代 `exists`+`isDir`+`exists`）的收益主要体现在：去掉 event loop 上的 3 次同步 `std.file` 调用（避免阻塞事件循环）、以及消除 `get()` 与 `sendFileImpl` 对同一文件的重复 stat（本次实测中 3→2 次在 15k RPS 量级差异不大）。
2. **404 + keep-alive 的 ab 统计失真**：`ab -k` 对非 2xx 响应会计为 Length 失败并断开连接，导致虚高（实测 `/manual/nope.js` keep-alive 下报 24 321 RPS 但 6 705 failed、Non-2xx 5 000），且服务端刷屏 `ERROR - HTTP connection handler has thrown ... Connection closed while writing data`（客户端收到非 2xx 后断开所致）。因此 404 场景改用不带 `-k` 重测，数字可信。
3. **gzip 场景初测即发现严重 bug（双重压缩），已修复**：
   - 现象：`Accept-Encoding: gzip` 请求返回 `Content-Encoding: gzip` + `Transfer-Encoding: chunked`（无 `Content-Length`），且**内容为 `gzip(app.js.gz)` 双重 gzip**（实测下载 11 415B，zcat 一次得到 11 392B，与磁盘上的 `app.js.gz` 完全一致）。浏览器解压一层后拿到的是 gzip 字节 → JS/CSS/JSON 解析失败，前端资源实际损坏。
   - 根因：vibe-http 1.5.1 的 `bodyWriter` 在响应存在 `Content-Encoding: gzip` 头时（`internal/http1/server.d`），会**移除 `Content-Length` 并在 bodyWriter 外再包一层 gzip 输出流**（假定应用写的是未压缩内容、由它动态压缩）。micdn 写入的已是预压缩 sidecar 字节，被二次压缩。
   - 单测未暴露：`file_test.d` 的 gzip 用例用 `TestHTTPResponseMode.bodyOnly`，测试响应直接使用预置 bodyWriter，绕过了该分支，未覆盖真实 HTTP 路径。
   - 修复：`sendFileImpl` 的 gzip 分支改用 `res.writeRawBody(...)`（vibe 明确「不做任何进一步编码」的原始写通道），`Content-Length` 保留；`file_test.d` 的 gzip 用例改用 `TestHTTPResponseMode.plain` 走真实 HTTP1 写出路径，断言 wire 头带 `Content-Length`、无 `Transfer-Encoding: chunked`、单次解压即原始内容。
   - 修复后验证：响应头 `Content-Encoding: gzip` + `Content-Length: 11392`（无 chunked）；下载 11 392B，单次解压得到 138 250B 原始 `app.js`。压测 11 378 RPS、0 失败、keep-alive 100%。

4. **最坏路径复测**：修复后 `/manual/` 复测 21 017 RPS（初测 15 601），0 失败——同机两次运行存在负载/频率差异（初测时 CPU scaling 36%），结论不变：5 次 stat 下单机仍有 1.5~2 万 RPS 量级。

## 复现

```bash
./scripts/stress_http.sh http://127.0.0.1:8899/manual/          # 最坏路径
./scripts/stress_http.sh http://127.0.0.1:8899/manual/app.js    # 文件命中
ab -k -r -n 10000 -c 100 http://127.0.0.1:8899/manual/          # 直接调 ab

# gzip 双重压缩验证（任意可压缩文件）：
curl -s -H 'Accept-Encoding: gzip' http://127.0.0.1:8899/manual/app.js -o /tmp/got.gz
zcat /tmp/got.gz | file -    # 仍为 gzip compressed data 即双重压缩
```
