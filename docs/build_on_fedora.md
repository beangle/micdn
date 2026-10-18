# Fedora 构建与 COPR 发布说明

本文说明在 **Fedora** 上编译 micdn、打 **RPM / SRPM**，以及通过 **COPR**（https://copr.fedorainfracloud.org/）向 Fedora 用户分发的完整流程。多发行版通用的编译与打包说明见 **[build_linux.md](./build_linux.md)**；安装后运维见 **[maintenance.md](./maintenance.md)**。

---

## 前置条件

```bash
sudo dnf install ldc dub gcc zlib-devel openssl-devel \
  rpm-build fakeroot gzip binutils git
```

工具链版本需满足 `dub.json` 中的 `toolchainRequirements`（**dub ≥ 1.34**、**LDC ≥ 1.32**）。

---

## 本地编译

```bash
dub build --build=release-nobounds --compiler=ldc2
# 产物：target/micdn
```

Fedora 的 ldc 包默认**动态**链接 druntime / Phobos（`ldc2.conf` 注入 `-link-defaultlib-shared`）；`ldd target/micdn` 出现 `libdruntime-ldc-shared.so` 属正常，目标机需有对应运行时（由 dnf 自动拉取）。链接方式与交付体检详见 **[build_linux.md](./build_linux.md)**。

---

## 本地 RPM / SRPM

```bash
./scripts/build_rpm.sh    # target/micdn-<版本>.<arch>.rpm
./scripts/build_srpm.sh   # target/micdn-<版本>-1.<dist>.src.rpm
```

- 版本取自**最近的 git tag**（如 `v0.4.0` → `0.4.0`），打新版本前先打 tag。
- SRPM 的 spec 使用 **`Release: 1%{?dist}`**：dist 由构建目标展开（本机 Fedora 44 上是 `1.fc44`，在 rawhide mock/COPR 里则是对应 dist），**同一份 SRPM 可在多个 Fedora / RHEL 系目标重编**，不必按宿主机写死。
- spec 含 **`%global _enable_debug_packages 0`**：LDC 产物无 debugedit 可识别的 DWARF，不关闭会因 `Empty %files file .../debugsourcefiles.list` 构建失败（见文末常见问题）。
- `%build` 中 `dub fetch` 需要**联网**拉取 D 依赖；本地 `rpmbuild --rebuild` 正常出网即可，COPR 上则必须开启构建期联网（见下节）。

用 SRPM 在本机出二进制 RPM 验证：

```bash
sudo dnf builddep target/micdn-*.src.rpm
rpmbuild --rebuild target/micdn-*.src.rpm
```

---

## COPR 发布

COPR 是 Fedora 官方托管的第三方构建仓库：无需官方包审核，上传 SRPM 即可为多个 Fedora 版本自动构建，用户以 `dnf copr enable` 方式安装。

beangle 系列工具共用一个 COPR 项目 **chaostone/beangle**（**https://copr.fedorainfracloud.org/coprs/chaostone/beangle/**）：一个项目下挂多个独立 RPM 包（`micdn`、`jstart`、`basctl`……），用户 `dnf copr enable` 一次即可安装全部包；各包独立版本、独立 spec、独立发布节奏。

### 一次性准备

1. **Fedora 账号**：https://accounts.fedoraproject.org/ 注册并登录 COPR（网页登录走 **OIDC login**，跳转账号系统完成；`gssapi-login` 是 Kerberos 通道，普通账号用不了）。
2. **API token**：登录后打开 https://copr.fedorainfracloud.org/api/ ，生成 token（页面给出的 `[copr-cli]` 配置块三行值须**原样一起复制**）。
3. **copr-cli 配置**：保存到 **`~/.config/copr`**（注意是**文件**，不是 `copr/config` 子目录）：

   ```ini
   [copr-cli]
   login = <API页面给的login值>
   username = < Fedora 用户名>
   token = <API页面给的token值>
   copr_url = https://copr.fedorainfracloud.org
   ```

   **`login` 不是 Fedora 用户名**：OIDC 账号的 login 是 API 页面给出的一串随机字符，与 `username` 不同，照抄即可。`copr-cli whoami` 只打印本地 `username`，**不验证** token；以 `copr-cli list` 或实际操作是否报 `Login invalid/expired` 为准。

### 创建项目（首次）

```bash
copr-cli create beangle \
  --chroot fedora-44-x86_64 \
  --chroot fedora-43-x86_64 \
  --chroot fedora-rawhide-x86_64 \
  --enable-net on \
  --description "Beangle family tools: micdn (minimal CDN), jstart, basctl, ..." \
  --instructions "sudo dnf copr enable chaostone/beangle && sudo dnf install micdn"
```

- **`--enable-net on` 必须**：micdn 的 spec 在 `%build` 里 `dub fetch` 要访问 code.dlang.org，COPR 构建 chroot 默认断网。
- chroot 按需增删（`copr-cli list-chroots` 查看可用列表）。
- 后续新增包（jstart、basctl 等）不需要新项目：各自出 SRPM 后 `copr-cli build beangle <srpm>` 即挂到同一项目下。

### 提交构建

```bash
./scripts/build_srpm.sh
copr-cli build beangle target/micdn-*.src.rpm
```

查看进度与结果：

```bash
copr-cli list-builds beangle
copr-cli status <build-id>
```

构建日志（失败排查）：

```
https://download.copr.fedorainfracloud.org/results/chaostone/beangle/<chroot>/<build-id>-micdn/builder-live.log.gz
```

### 用户安装

```bash
sudo dnf install 'dnf5-command(copr)'   # Fedora 41+ 的 copr 插件
sudo dnf copr enable chaostone/beangle
sudo dnf install micdn                  # 项目下其它包按需安装
```

二进制动态链接 ldc 运行时，安装时 dnf 自动拉取 `ldc-libs`，无需手动预装。

曾启用过旧项目的用户（`chaostone/micdn` 已并入 `chaostone/beangle` 后删除）执行一次清理，避免 dnf 刷新时报仓库不可用：

```bash
sudo dnf copr disable chaostone/micdn
```

**下载路径说明**：COPR 生成的 `.repo` 是写死的 `baseurl`（`download.copr.fedorainfracloud.org`），**不走 Fedora MirrorManager**，国内无镜像、一律直连美东；micdn 本体 RPM 约 5MB，一次下载即可。依赖包（`ldc-libs` 等）来自 Fedora 官方源，正常走清华、中科大等国内镜像，不受影响。

---

## 发布新版本

1. 上游打 tag 并推送：`git tag v0.4.1 && git push origin v0.4.1`
2. 本机出 SRPM：`./scripts/build_srpm.sh`
3. 提交 COPR：`copr-cli build beangle target/micdn-0.4.1-*.src.rpm`
4. 构建成功后用户 `sudo dnf update micdn` 即可升级

---

## 常见问题

**Q：构建报 `Empty %files file .../debugsourcefiles.list`**

Fedora 默认自动生成 `-debuginfo` / `-debugsource` 子包，而 LDC 编译产物没有 debugedit 能识别的调试信息，文件列表为空即失败。spec 里已有 `%global _enable_debug_packages 0` 关闭该机制；基于旧 SRPM 重编时请换用含此行的新 SRPM。

**Q：`copr-cli` 报 `Login invalid/expired`**

按顺序检查：`~/.config/copr` 是**文件**而非目录；`login` 是否为 API 页面给的随机串（不是用户名）；token 是否完整复制（当前生成的 token 为 30 字符）；必要时在网页上重新生成 token（旧 token 同时作废）。

**Q：构建成功但结果目录里只有日志、没有 RPM**

新版 COPR 将产物放在 Pulp 存储，经典 results 目录只保留日志与 `results.json`（内含包名/版本/架构）。以 `results.json` 与 `copr-cli status` 为准，用户侧 `dnf` 安装不受影响。

**Q：COPR 网页访问很慢**

COPR 托管在美东，国内访问延迟高属正常；且本机 IPv6 解析到该域名不通时浏览器会先等超时再回落 IPv4。创建项目、提交构建、查状态均可用 `copr-cli` 完成，仅首次生成 API token 需要网页操作。

**Q：国内用户安装 COPR 包会走镜像吗**

不会。COPR 仓库不在 Fedora 镜像网络内，`.repo` 直指 `download.copr.fedorainfracloud.org`，所有用户直连美东。若将来国内用户量大、反馈慢，可将 RPM 同步到 GitHub Release 或自建镜像站分发；现阶段 micdn 体积小（约 5MB），直连即可。

**Q：如何把其它 beangle 仓库（jstart、basctl）也放进同一项目**

各自写好 spec、打成 SRPM 后执行 `copr-cli build beangle <srpm>`，即成为该项目下新的独立包；用户已 enable 过 `chaostone/beangle` 的无需再操作，直接 `dnf install` 新包。包多了以后可改用 SCM 方式（`copr-cli add-package-scm`）绑定各 git 仓库，push 后自动构建。
