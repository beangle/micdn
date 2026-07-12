# Micdn v0.2.6 Release Notes

**发布日期：** 2026-07-12  
**对比基线：** [v0.2.5](https://github.com/beangle/micdn/compare/v0.2.5...v0.2.6)

---

## 概要

v0.2.6 在 v0.2.5 基础上：**CLI `mount` 更名为 `deploy`**、新增 **www zip 自动 deploy（Linux inotify）**、调整 **GC 池策略并简化 metrics 内存指标**，并修复 auto-deploy 在源文件不可读时误删已部署内容的问题。

**`micdn.xml` 配置格式无 Breaking Change**（与 v0.2.5 兼容）。运维脚本若仍调用 `micdn … mount`，需改为 `deploy`。

---

## 亮点总结

| 类别 | 改进 |
|------|------|
| **CLI** | `mount` → `deploy`；`resolve` / `deploy` 日志固定走控制台 info |
| **WWW** | `auto-deploy="true"`：运行期监听 zip 目录，写入/rename 后自动 deploy |
| **可靠** | 源 zip/tgz 已更新但进程不可读时**保留**已有解压目录，避免 404 |
| **内存** | 内置 `maxPoolSize=8M`、`heapSizeFactor=1.2`；移除 idle `GC.minimize` |
| **可观测** | metrics 增加 `gcCollections`、`gcMaxPoolSize`；移除 `gcMinimize` 计数 |

---

## 新功能

### CLI：`deploy`（原 `mount`）

```bash
micdn -f /etc/micdn/micdn.xml deploy www
micdn -f /etc/micdn/micdn.xml deploy static
micdn -f /etc/micdn/micdn.xml deploy www manual --force
```

- 子命令 **`mount` 已移除**，请改用 **`deploy`**
- 新写入的 `manifest.json` 使用字段 **`deployedAt`**（旧 manifest 不含该字段亦可正常走快路径跳过）
- `resolve` 与 `deploy` 的 info 日志**不读** `micdn.xml` 的 `log-file` / `log-level`，便于 cron/systemd 直接查看

### WWW zip 自动 deploy（Linux）

```xml
<doc name="manual" zip="/var/lib/micdn/releases/manual.zip" inner="dist" auto-deploy="true" />
```

- HTTP 服务运行期 inotify 监听 zip **所在目录**（`IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE`）
- 源 zip 写入完成或替换后 debounce 400ms 自动 `deploy`；manifest 未变则 **Caching** 跳过解压
- **不订阅 `IN_ATTRIB`**：`chmod`/`chown`  alone 不会触发；权限修好后需再次写入 zip 或手动 deploy
- 非 Linux 启动时对该 doc 打 WARN 并忽略 auto-deploy

详见 [maintenance.md](./maintenance.md)。

### 运行期 GC 配置

HTTP 启动时内置（**不可通过 micdn.xml 修改**）：

| 参数 | 值 |
|------|-----|
| `maxPoolSize` | **8M**（单块 GC pool 上限） |
| `heapSizeFactor` | **1.2** |

启动日志：`Runtime profile: GC maxPoolSize=8M heapSizeFactor=1.2`

---

## 行为变更

### 移除 idle `GC.minimize`

v0.2.5 的 15 分钟 idle 定时 `GC.minimize()` **已移除**（`gcCollections` 随负载自然增长，周期性 minimize 收益有限）。metrics JSON/HTML 不再包含 `gcMinimize`。

### Metrics 内存字段

| 字段 | 说明 |
|------|------|
| `gcCollections` | 自启动以来 druntime full GC 次数 |
| `gcMaxPoolSize` | 当前 `maxPoolSize` 配置（字节） |
| ~~`gcMinimize`~~ | 已移除 |

HTML 仪表盘顶栏与 Limits 区改为三列对齐布局。

---

## Bug 修复与可靠

### 不可读源文件不删已部署内容

全量 deploy 前增加 `access(R_OK)` 检查。若 zip/tgz 已更新（size/mtime 变）但 micdn 进程**无读权限**：

- **不**调用 `clearDeployDir`
- 打 WARN：`Deploy source is not readable, keeping existing deploy: …`
- 继续服务旧解压内容；auto-deploy 日志为 failed

**建议发布流程：** `install -o micdn -g beangle -m 664` 或 mv 时保证属主/权限正确，避免 root 覆盖成不可读。

---

## 其它

- 新增 **`scripts/stress_http.sh`**：基于 ApacheBench 的 HTTP 压测（`-c` 并发、`-n` 总请求）

---

## 依赖

与 v0.2.5 相同（`dub.selections.json` 未变）：

| 包 | 版本 |
|----|------|
| vibe-http | 1.5.1 |
| vibe-inet | 1.3.1 |
| vibe-stream | 1.4.1 |
| vibe-d:web | 0.10.3 |
| dxml | 0.4.5 |

---

## 升级注意

1. 安装 v0.2.6 后 `systemctl restart micdn`
2. **脚本/cron** 将 `micdn … mount` 改为 **`micdn … deploy`**
3. 若使用 zip auto-deploy，确认 zip 目录与文件对 **micdn 用户可读**（见 maintenance 权限说明）
4. 升级后可选执行：
   ```bash
   micdn -f /etc/micdn/micdn.xml resolve
   ```
5. 查看指标：
   ```bash
   curl -s http://127.0.0.1:8080/admin/metrics.json | jq '.memory'
   ```

---

## 测试

92 个单元测试通过，含 `autodeploy_test.d`、不可读源保留 deploy 的 `file_test.d`、`metrics_test.d` 等。
