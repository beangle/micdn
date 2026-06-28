# Micdn v0.2.5 Release Notes

**发布日期：** 2026-06-27  
**对比基线：** [v0.2.4](https://github.com/beangle/micdn/compare/v0.2.4...v0.2.5)

---

## 概要

v0.2.5 在 v0.2.4 基础上增加 **部署前校验 CLI**、**静态资源 sendFiles 内存路径修复**，以及 **localhost 只读运维指标与 idle 内存收缩**：便于上线前检查配置与 artifact、长期运行后观察 RSS/负载，并在低负载时把 D GC 堆归还 OS。

**无 `micdn.xml` 配置格式 Breaking Change**（与 v0.2.4 兼容）。

---

## 亮点总结

| 类别 | 改进 |
|------|------|
| **CLI** | `micdn -f CONFIG validate` 校验 XML/属性、listen、根目录可写、本地 GAV/dir/zip/jar/npm |
| **修复** | `sendFiles` 小文件合并走内存读出，避免 `FileStream` 泄漏告警 |
| **可观测** | `/admin/metrics.json` + `/admin/metrics` HTML 仪表盘（仅 localhost） |
| **内存** | 内置 idle `GC.minimize`（15 分钟周期，RSS ≥ 20MB 且在途请求 ≤ 200） |

---

## 新功能

### CLI：`validate`

```bash
micdn -f /etc/micdn/micdn.xml validate
```

- 解析配置与 `listen`，检查各服务数据根目录可写
- 校验 www/static 所需 **本地** artifact（GAV、dir、zip、jar、npm）是否已 mount，**不下载、不解压、不启动 HTTP**
- 成功：`validate ok: …`，退出码 **0**；失败：stderr + 退出码 **2**（与启动失败一致，便于 systemd）

说明见 [maintenance.md](./maintenance.md)。

### Admin 指标（只读）

| 端点 | 说明 |
|------|------|
| `GET /admin/metrics.json` | JSON，供 curl / Prometheus 等采集 |
| `GET /admin/metrics` | HTML 仪表盘，5s 自动刷新 |

**仅允许 localhost**（含 `127.0.0.1:port`、`::1`、`::ffff:127.0.0.1`）。

主要字段：

- **负载**：`requests.total` / `active` / `activeMax`，`tcp.established` / `establishedMax`，平均 req/s（由 total/uptime 推算）
- **进程**：`pid`、`uptimeSeconds`、`listenPort`、`process.openFds`、`process.threads`
- **内存**：`memory.rssKb`、`hwmKb`、`gcUsed`、`gcFree`
- **运维**：`reload`、`gcMinimize`、`handlerErrors`（未预期的非 HTTP 异常）
- **限制**：`limits.maxRequestSize`、`keepAliveTimeoutSec`（`maxConnections` 为 -1 表示未设上限）

请求路径上仅 **少量原子计数**（total/active/峰值）；`/proc` 与 TCP 统计仅在访问 metrics 时读取。

原有 **`/admin/config.xml`**、**`/admin/reload`**（localhost）行为不变。

### Idle GC 内存收缩

后台定时器（**不可通过 micdn.xml 配置**）：

| 参数 | 值 |
|------|-----|
| 检查间隔 | 15 分钟 |
| 触发条件 | RSS ≥ **20 MB** 且 `requestsActive` ≤ **200** |
| 冷却 | 两次 minimize 至少间隔 15 分钟 |
| 动作 | `GC.collect()` + `GC.minimize()`（Linux 上含 `malloc_trim`） |

不在每个 HTTP 请求上读 `/proc` 或数连接；reload 成功后更新 metrics 的 `listenPort`（供 `tcp.established` 展示）。

---

## Bug 修复

### `sendFiles` 小文件合并

静态资源逗号合并 URI（如 `/static/bundle/a.js,b.js`）在合并后总大小 ≤ 8MB 时，改为 **`readFile` + 单次 `bodyWriter.write`**，与 `sendFile` 小文件路径一致，避免 `FileStream` 经 `pipe(bodyWriter)` 在长跑进程中被 GC 回收时触发 vibe 泄漏告警。

---

## 升级注意

1. 安装 v0.2.5 后 `systemctl restart micdn`（或等价方式）
2. 升级后建议执行一次 validate（需已 mount 的本地 artifact）：
   ```bash
   micdn -f /etc/micdn/micdn.xml validate
   ```
3. 本机查看指标：
   ```bash
   curl -s http://127.0.0.1:8080/admin/metrics.json | jq .
   # 浏览器打开 http://127.0.0.1:8080/admin/metrics
   ```
   （端口以 `listen` 为准。）
4. metrics/reload 仅绑定 localhost；若前面有反向代理，请勿把 `/admin/*` 暴露到公网。

---

## 测试

新增/扩充：

- `test/micdn/validate_test.d`、`test/micdn/config_test.d`
- `test/micdn/web/file_test.d`（sendFiles 小文件内存路径）
- `test/micdn/admin/*`（metrics、memstats、idle_gc、access）

---

## 完整提交列表

- `Add validate CLI and document deployment checks.`
- v0.2.5：admin metrics、idle GC、`sendFiles` 修复、版本号与发布说明
