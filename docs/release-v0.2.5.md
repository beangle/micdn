# Micdn v0.2.5 Release Notes

**发布日期：** 2026-06-28  
**对比基线：** [v0.2.4](https://github.com/beangle/micdn/compare/v0.2.4...v0.2.5)

---

## 概要

v0.2.5 在 v0.2.4 基础上增加 **部署前解析 CLI（`resolve`）**、**静态资源 sendFiles 内存路径修复**、**localhost 只读运维指标与 idle 内存收缩**，并整理 admin 模块、升级 vibe 栈依赖。

**无 `micdn.xml` 配置格式 Breaking Change**（与 v0.2.4 兼容）。

---

## 亮点总结

| 类别 | 改进 |
|------|------|
| **CLI** | `micdn -f CONFIG resolve` 解析配置并安装 www/static（下载 jar/npm、解压 zip/tgz，校验挂载目录） |
| **修复** | `sendFiles` 小文件合并走内存读出，避免 `FileStream` 泄漏告警 |
| **可观测** | `/admin/metrics.json` + `/admin/metrics` HTML 仪表盘（`views/metrics.dt`，仅 localhost） |
| **内存** | 内置 idle `GC.minimize`（15 分钟 tick，RSS ≥ 50MB 且在途请求 ≤ 200） |
| **依赖** | vibe-http 1.5.1、vibe-inet 1.3.1、vibe-stream 1.4.1 |

---

## 新功能

### CLI：`resolve`

```bash
micdn -f /etc/micdn/micdn.xml resolve
```

- 解析配置与 `listen`，检查各服务数据根目录可写
- 下载缺失 jar/npm、解压 zip/tgz，mount 全部 www/static，校验 zip/npm **inner `dir`** 与挂载目录；**不启动 HTTP**
- 成功：`resolve ok: …`，退出码 **0**；配置解析失败退出码 **2**；部署失败退出码 **1**
- 等同 `mount www` + `mount static`（不支持 `--force`）；见 [maintenance.md](./maintenance.md)

### Admin 指标（只读）

| 端点 | 说明 |
|------|------|
| `GET /admin/metrics.json` | JSON，供 curl / Prometheus 等采集 |
| `GET /admin/metrics` | HTML 仪表盘（diet 模板 `views/metrics.dt`），5s 自动刷新 |

**仅允许 localhost**（含 `127.0.0.1:port`、`::1`、`::ffff:127.0.0.1`）。

- 指标逻辑合并于 **`micdn.admin.metrics`**（含 RSS/GC 读取、idle GC、原子计数）
- 主要字段：请求数/在途/峰值、TCP established、RSS/HWM、GC used/free、open FDs、reload、gcMinimize 等
- 请求路径上仅 **少量原子计数**；`/proc` 与 TCP 统计仅在 scrape metrics 时读取

原有 **`/admin/config.xml`**、**`/admin/reload`**（localhost）行为不变。

### Idle GC 内存收缩

后台定时器（**不可通过 micdn.xml 配置**）：

| 参数 | 值 |
|------|-----|
| 检查间隔 | 15 分钟 |
| 触发条件 | RSS ≥ **50 MB** 且 `requestsActive` ≤ **200** |
| 动作 | `GC.collect()` + `GC.minimize()`（Linux 上含 `malloc_trim`） |

每个 tick 满足条件即执行（无额外冷却）；reload 成功后更新 metrics 的 `listenPort`。

---

## Bug 修复

### `sendFiles` 小文件合并

静态资源逗号合并 URI（如 `/static/bundle/a.js,b.js`）在合并后总大小 ≤ 8MB 时，改为 **`readFile` + 单次 `bodyWriter.write`**，避免 `FileStream` 经 `pipe(bodyWriter)` 在长跑进程中被 GC 回收时触发 vibe 泄漏告警。

---

## 依赖

| 包 | 版本 |
|----|------|
| vibe-http | **1.5.1** |
| vibe-inet | **1.3.1** |
| vibe-stream | **1.4.1** |
| vibe-serialization | **1.2.0** |
| vibe-d:web | 0.10.3 |
| dxml | 0.4.5 |

`vibe-stream:tls` 仍为 **`notls`**。

---

## 升级注意

1. 安装 v0.2.5 后 `systemctl restart micdn`（或等价方式）
2. 升级后建议执行一次 resolve（自动下载/挂载缺失 artifact）：
   ```bash
   micdn -f /etc/micdn/micdn.xml resolve
   ```
3. 生产构建请使用 **`dub build --build=release-nobounds --compiler=ldc2`** + **`strip`**（与 `build_rpm.sh` 一致）
4. 本机查看指标：
   ```bash
   curl -s http://127.0.0.1:8080/admin/metrics.json | jq .
   ```
5. metrics/reload 仅绑定 localhost；若前面有反向代理，请勿把 `/admin/*` 暴露到公网

---

## 测试

89 个单元测试通过，含 `resolve_test.d`、`metrics_test.d`、`web/file_test.d`、`admin/access_test.d` 等。
