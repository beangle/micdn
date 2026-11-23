# Micdn v0.4.3 Release Notes

**发布日期：** 2026-11-23
**对比基线：** [v0.4.2](https://github.com/beangle/micdn/compare/v0.4.2...v0.4.3)

---

## 概要

v0.4.3 把远程配置从 HTTP 投递改为 **root oneshot 安装**：micdn 不需要先启动，也不需要猜测
管理端口；同时增加配置检查命令和日志轮转。

## 配置安装

basagent 下载 `micdn.xml` 到 `/var/lib/bas/micdn/micdn.xml`（`bas:beangle 0600`），然后触发：

```text
sudo -n systemctl start basmicdn-apply.service
```

root helper（由 basctl 提供）：

1. 以 `micdn` 用户执行 `micdn --check`；
2. 备份当前 `/etc/micdn/micdn.xml`；
3. 原子替换目标文件，保持 `micdn:beangle 0640`；
4. `systemctl restart micdn.service`；
5. 检查 active，失败恢复旧配置并重启；
6. 写 `/var/lib/bas/micdn/apply.result`。

特点和边界：

- micdn 停止时也能应用；
- 不依赖 `/admin/config` 或 `listen` 端口；
- 配置校验失败时目标文件不变；
- restart 失败自动回滚；
- helper 不联网、不读取 `BAS_TOKEN`，只接受固定源路径；
- 同一节点用 `flock` 串行化 apply。

## 配置检查

新增：

```bash
micdn -f FILE --check
micdn -f FILE check
```

只解析并校验配置，不监听端口。检查以实际运行用户身份执行，`~` 会展开为该用户的 passwd home。

## 日志轮转

安装包新增 `/etc/logrotate.d/micdn`，默认：

```text
/var/log/micdn/micdn.log {
    daily
    rotate 14
    compress
    delaycompress
    copytruncate
    su micdn beangle
}
```

## 破坏性变更

- **移除 `POST /admin/config`**：basagent 不再投递 HTTP 配置；改用 `basmicdn-apply`。
- `/admin/config.xml` 和 `/admin/reload` 仍保留，供本机查看和手工 reload。

## 升级

1. 先升级 **micdn 0.4.3**（包含 `--check`）；
2. 再升级 **basctl/basagent 0.0.4**（包含 `basmicdn-apply`、unit 和 sudoers）；
3. `systemctl daemon-reload`，重启 basagent；
4. 验证：
   ```sh
   sudo -l -U bas
   sudo -u bas sudo -n /usr/bin/systemctl start basmicdn-apply.service
   ```
5. 可在 micdn 停止状态下从管理台触发 reload，确认自动启动并应用配置；
6. 旧版 basagent 不能再调用 `/admin/config`，必须同时升级。

## 测试

```text
dub test --compiler=ldc2：229 passed, 0 failed
```
