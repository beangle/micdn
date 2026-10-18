# Micdn v0.4.1 Release Notes

**发布日期：** 2026-10-18
**对比基线：** [v0.4.0](https://github.com/beangle/micdn/compare/v0.4.0...v0.4.1)

---

## 概要

v0.4.1 把远程配置下载从 `micdn.xml` 中移出，改为**只在 reload 时**读取与 XML 同目录的
`micdn.conf`。启动、`resolve`、`deploy`、`clean`、`install` 始终只使用本地 `micdn.xml`，
远程配置地址与访问 token 也不再进入会被下载、展示或分发的 XML。本版同时启用 FULL RELRO，
并补齐 SRPM、Fedora / COPR 与容器构建文档。

- **配置（Breaking）**：`<micdn remote="...">` 属性已移除，不再检查且没有 fallback。
- **reload bootstrap**：`micdn.conf` 的 `[remote] url` / `token` 只在 reload 时读取。
- **下载认证**：token 可选，以 `Authorization: Bearer` 发送；允许 `http://` 与 `https://`，不强制 HTTPS。
- **安全替换**：先写同目录临时文件，XML 解析校验通过后才原子替换 `micdn.xml`；失败时 reload 失败，
  旧路由继续服务。
- **打包**：RPM / deb / 容器镜像都会提供 `micdn.conf` 模板；systemd reload 仍只需发送 SIGHUP。
- **链接加固**：默认 `executable` 构建启用 FULL RELRO。
- **发布链路**：SRPM 可在不同 Fedora / RHEL 目标重编，新增 Fedora / COPR 发布说明。

## 远程配置

`micdn.conf` 为 INI 格式：

```ini
[remote]
url = http://cfg.example.com/micdn.xml
token = s3cret
```

规则：

- 文件必须与 `-f` 指向的 `micdn.xml` 同目录；例如 `-f /etc/micdn/micdn.xml` 对应
  `/etc/micdn/micdn.conf`。
- `url` 只接受 `http://` / `https://`。使用 HTTP 时 token 会以明文经过链路，只应在可信网络中使用。
- 文件不存在、没有 `[remote]` 段或 `url` 为空时，reload 只重新解析本地 XML。
- 下载失败、XML 无效或 `token` 含非法字符时，reload 失败，当前 router 保持不变。

## 安全加固

`dub.json` 的默认 `executable` 配置启用 `-z now`，生成带 **FULL RELRO** 的 `micdn`：
GOT 在加载时一次性解析并置为只读，请求路径上的 GOT 覆写无法再被转换成任意写原语。
该参数只作用于默认构建，`executable-static` 保持自己的链接参数。

```bash
readelf -d target/micdn | grep -E 'BIND_NOW|FLAGS'
readelf -lW target/micdn | grep -i relro
```

用 v0.4.0 或更早 tag 构建的包不带该加固；需要重新构建。PIE 与 FULL RELRO 是两项独立属性。

## systemd 与打包

RPM/deb 的 systemd 单元保持：

```ini
ExecStart=/usr/bin/micdn -f /etc/micdn/micdn.xml
ExecReload=/bin/kill -HUP $MAINPID
```

reload 自动从 `/etc/micdn/micdn.xml` 推导 `/etc/micdn/micdn.conf`，不需要额外的 systemd 参数：

```bash
sudo systemctl reload micdn
```

安装包提供 `/usr/share/micdn/micdn.conf.default`，首次安装由 `%post` / `postinst` 生成
`/etc/micdn/micdn.conf`。`/etc/micdn` 为 `root:beangle 2775`，`micdn.conf` 为
`root:beangle 0640`，服务用户可读但其他用户不可读。`/etc/micdn/micdn.conf` 与
`/etc/micdn/micdn.xml` 一样不在包文件清单中，升级不覆盖、卸载保留。

### SRPM 与 Fedora / COPR

SRPM 的 spec 使用 `Release: 1%{?dist}`，同一份源码包可在 Fedora / RHEL 系的 mock、COPR、
koji 多目标重编；同时关闭自动 debuginfo / debugsource 子包，避免 LDC 产物生成空文件列表而失败。

Fedora 上的本地打包与 COPR 发布流程见 [build_on_fedora.md](build_on_fedora.md)。micdn 与
其他 Beangle 工具共用一个 COPR 项目 `chaostone/beangle`；COPR 构建需开启构建期联网，
因为 `%build` 中的 `dub fetch` 要访问 code.dlang.org。

### 文档修正

- 容器构建文档重命名为 `docs/build_container.md`。
- AUR 文档明确 `/etc/micdn/micdn.xml` 不在包内，不应写入 `backup=`；并补充
  pacman `pre_remove` 的调用时机与 `$1` 语义。
- v0.4.0 release notes 的提交数与测试数修正为 29 个非合并提交、224 passed。

## 升级注意

1. 删除 `micdn.xml` 根元素上的 `remote` 属性；需要远程刷新时改用 `micdn.conf`。
2. 确认 `/etc/micdn` 对服务用户可写，以便 reload 原子替换下载的 XML；安装包已设置好该权限。
3. 执行 `sudo systemctl reload micdn`。启动本身不会访问远程配置。
4. 若 reload 后要使用新的 `www` / `static`，再执行 `resolve` / `deploy`。

> RPM、deb 与容器镜像的版本仍从 git tag 推导。发布 `0.4.1` 前需创建并推送 `v0.4.1` tag；
> 仅修改 `getVersion()` 不会改变安装包文件名或镜像 tag。

## 测试

`dub test --build=unittest --compiler=ldc2`：**228 passed, 0 failed**。
