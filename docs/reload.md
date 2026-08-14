# micdn 配置热加载（reload）备忘

> 本文梳理 micdn 的 reload 设计、触发方式、工作流程与生效边界，供维护与排障参考。

---

## 概述

- reload = **重新解析配置 + 重建整套路由/服务树 + 原子替换**，进程不重启；新配置立即生效。
- 两个入口：**SIGHUP**（Linux）与 **`/admin/reload`**（localhost），最终都汇到 `reloadAndSync`。
- 失败语义：解析或构建失败时**保留旧 router 继续服务**，仅记录 metrics 并打错误日志，配置不生效。

---

## 触发方式

| 方式 | 命令 | 说明 |
|------|------|------|
| SIGHUP | `sudo systemctl reload micdn`（等价 `kill -HUP $MAINPID`） | systemd 单元已配置 `ExecReload=/bin/kill -HUP $MAINPID`；**仅 Linux 编译启用** |
| HTTP | `curl http://127.0.0.1:8080/admin/reload` | 仅接受 localhost 回环来源；成功返回 `reload ok`，失败返回 `reload failed: <msg>` |

**注意**：非 Linux（macOS/BSD 等）不编译 SIGHUP 监听线程，只可用 `/admin/reload`。

---

## 工作流程

1. **拉取配置**：`fetchRemoteIfNeeded`——本地配置含 `remote` 属性时先重新下载覆盖（`src/micdn/web/package.d`）。
2. **重新解析**：`parseFile` 完整解析并校验（XSD、名称/base、try-file、重复 doc 等）。
3. **解析监听**：`parseListen` 读取新 `host:port`（仅用于 metrics，见「生效范围」）。
4. **应用限制**：`applyLimits` 把新 `blob.maxSize`、`keepAliveTimeout` 写回共享 `HTTPServerSettings`，对新连接生效。
5. **重建路由**：`buildRouter` 新建 admin/static/maven/npm/blob/www 全套服务对象；www 经 `WwwRepo.build` **重建发布期索引**。
6. **原子替换**：`_currentRouter = router`——替换只发生在事件循环线程，无需加锁（`src/micdn/main.d` `ReloadableDispatcher`）。
7. **收尾同步**：`reloadAndSync` 更新 metrics 的 `listenPort`，并 `wwwAutoDeploy.restart` 按新配置重建 inotify 监听。
8. **内存回收**：成功后立即 `runGcMinimize`（与启动期重活后回收一致），让旧路由/索引垃圾占用的 RSS 回落，日志 `Reload GC reclaim: …`。
9. **记录指标**：`recordReload(ok)` 计入 `reload.total` / `reload.failed`（`src/micdn/admin/metrics.d`）。

**日志**：`tryReload` 入口打 `Config reload started: <配置路径>`；成功时 SIGHUP 路径打 `Config reload (SIGHUP): ok`、HTTP 路径打 `Config reload (HTTP): ok`；失败统一打 `Reload failed: <msg>`。

**SIGHUP 的实现要点**（`src/micdn/main.d` `startSighupReloadThread`）：

- 专用线程 `sigprocmask(SIG_BLOCK, SIGHUP)` + `sigwait` 循环接收信号。
- 信号线程**不直接执行 reload**（`runTask` 会落在不消费任务队列的线程），改为经 **eventcore 跨线程事件** `events.trigger` 唤醒事件循环，再在事件循环内 `runTask` 执行。

---

## 生效范围

**reload 生效：**

- 路由与端点：www doc / static bundle / blob bucket 的新增、删除、属性调整。
- 配置期校验：重复 doc name、非法 base / bundle / bucket 名、`try-file` 含路径等，reload 时同样报错。
- 请求限制：`blob.maxSize`、`keepAliveTimeout`（对新连接）。
- www 发布期索引：随 `buildRouter` 整体重建。
- autodeploy 监听：zip 路径、`auto-deploy` 开关变更后按新配置重建。
- `/admin/config.xml` 展示的配置同步为新配置。

**reload 不生效（需 restart）：**

- 监听 `host:port`：listener 在启动时已绑定，reload 只更新 metrics 中的端口字段，**不真正重绑**。
- 日志 `log-file` / `log-level`：启动时应用一次。
- GC 参数与 runtime profile：druntime 启动前读取，运行期不可改。
- 进程级 `uptime`：保持进程启动时间。

---

## 失败处理与可观测

- 失败日志：`Reload failed: <msg>`（`/admin/reload` 返回 500）或 `Config reload (SIGHUP): failed: <msg>`。
- 指标：`GET /admin/metrics.json` 中的 `reload.total` / `reload.failed`。
- 排查：`journalctl -u micdn` 查看 reload 前后的日志；对比 `/admin/config.xml` 确认当前生效配置。

---

## 与其它机制的关系

- **autodeploy（运行期）**：zip 变更 → inotify → 400ms debounce → `deployDoc` → `WwwService.invalidateDoc` 只重建**单个 doc** 的索引；与 reload 的整体重建相互独立。
- **GC**：reload 成功后立即 `runGcMinimize` 回收一次（旧路由/索引垃圾随之下落）；周期回收（10 分钟）仍兜底，`/admin/reclaim` 可手动按需。
- **上线流程建议**：改配置后先 `resolve`（两阶段校验 + 部署 www/static）再 reload 生效；涉及端口、日志级别等非热加载项时用 `restart`。

---

## 运维备忘

1. 修改配置前先校验：`sudo -u micdn micdn -f /etc/micdn/micdn.xml resolve`（详见 [maintenance.md](./maintenance.md)）。
2. 端口与日志级别改动**必须 restart**，reload 不会生效。
3. `/admin/*` 仅监听 localhost；反向代理请勿把 `/admin/*` 转发到公网。
4. reload 只影响本进程：多实例部署时需对每个实例分别触发。
5. 变更后确认结果：查看 `reload.total/failed` 与 `/admin/config.xml`，确认新配置已生效。
