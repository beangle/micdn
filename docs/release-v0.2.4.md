# Micdn v0.2.4 Release Notes

**发布日期：** 2026-06-06  
**对比基线：** [v0.2.3](https://github.com/beangle/micdn/compare/v0.2.3...v0.2.4)

---

## 概要

v0.2.4 在 v0.2.3 基础上聚焦 **挂载性能与可靠性**：用 `manifest.json` 跳过未变更的 jar/npm/zip 解压，简化慢路径逻辑；单个 doc/bundle 挂载失败不再拖垮整进程；修正 RHEL 系 systemd unit 兼容性；并补充打包与 AUR 文档。

共 **9 个提交**，**17 个文件**变更（+734 / −124 行）。

---

## 亮点总结

| 类别 | 改进 |
|------|------|
| **挂载加速** | 源文件 size/mtime 未变时写 `Caching …` 并跳过解压 |
| **强制重装** | `mount … --force` 删除挂载目录后全量解压（忽略 manifest） |
| **启动容错** | 挂载前探测目录可写；单 doc/bundle 失败 `logError` 后服务仍 listen |
| **systemd** | `StartLimitInterval=` 置于 `[Service]`，兼容 el7 / el8 / Fedora |
| **日志** | curl 下载成功/失败各一条；manifest 快路径由 `Skipping` 改为 `Caching` |
| **打包** | RPM/DEB 增加 home/vendor；新增 AUR 构建说明 |

---

## 新功能

### manifest.json 挂载缓存

jar / npm(tgz) / zip 解压成功后，在挂载目录写入 `{docBase}/manifest.json`，记录：

- `artifact`（GAV 或 npm spec）
- `source.inner`、`source.size`、`source.mtime`、`source.fileCount`
- `mountedAt`

下次 mount 或启动 build 时，若 manifest 与源文件一致，打 **`Caching org.webjars:…...`** 并跳过解压。

manifest 无效或源已变更时：**删除 docBase → 全量解压 → 重写 manifest**（不再逐文件 CRC/大小比对）。

### CLI：`mount --force`

```bash
micdn -f micdn.xml mount www manual --force
micdn -f micdn.xml mount static bootstrap --force
```

删除已有挂载目录（`Removing …`）后重新安装，忽略 manifest 快路径。适用于手改 docBase 内容但 jar/tgz 未变的场景。

### 挂载容错

- **`verifyMountDirWritable`**：解压前探测 `.micdn-write-probe`，权限问题尽早失败
- **`mountDoc` / `mountBundle`** 外围 `try/catch`：单个模块失败记 `logError`，**HTTP 服务仍启动**（CLI `mount` 仍 exit 1）

### curl 下载日志

`curlDownload` 成功：`Downloaded url -> local (bytes, time)`；失败：`Download failed …`（`--silent --show-error`）。

---

## Bug 修复 / 运维

### systemd（RHEL 系）

- 修正 `StartLimitIntervalSec` 写在 `[Service]` 导致 el8 journal 报 `unknown lvalue` 的问题
- 改用 **`StartLimitInterval=120`** 放在 **`[Service]`**，el7(219)～Fedora 均可识别
- `RestartPreventExitStatus=2` 在 el8+/Fedora 生效；**el7 无此选项**，坏配置仍可能短暂反复重启（启动限流仍有效）

### 其它

- `getVersion()` 与 `dub.json` 同步为 **0.2.4**

---

## 打包与文档

- **`docs/build_aur.md`**：Arch Linux AUR 打包说明
- **`docs/build_linux.md`**：补充 LDC 静态/动态链接与本地环境说明
- RPM/DEB/SRPM：`/home`、`/vendor` 目录纳入包布局

---

## 升级注意

**无配置格式 Breaking Change**（与 v0.2.3 配置兼容）。

建议步骤：

1. 安装 v0.2.4 RPM/DEB
2. `systemctl daemon-reload && systemctl restart micdn`
3. 若曾手改挂载目录内容、需与上游 artifact 对齐：`micdn -f /etc/micdn/micdn.xml mount www --force`（或指定 doc/bundle）
4. 首次升级后慢路径 mount 会重写 `manifest.json`，属正常现象

---

## 测试

`test/micdn/fs/file_test.d` 扩充：manifest 快路径/跳过、`--force` 重装、zip 安全 entry、tgz innerDir、`verifyMountDirWritable` 等。

---

## 完整提交列表

- `Speed up static/www mounts with manifest.json and improve download logs`
- `Simplify mount slow path: drop per-file CRC refresh in refreshUnzip`
- `Harden mounts and fix systemd unit for el7–Fedora`
- `add build aur` / `add home and vendor to rpm/deb` / `declear static/dynamic link style depends local ldc env`
- `Rename mount skip log from Skipping to Caching`
- `Sync getVersion() with 0.2.4 release`
