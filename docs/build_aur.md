# Arch Linux（AUR）构建与发布说明

本文说明 **AUR 维护者**如何更新、构建并发布 `micdn` 包。AUR 仓库通常单独维护在 `~/aur-packages/micdn`，与上游 GitHub 仓库分离。

Fedora/RHEL 等 RPM 打包见 **[build_linux.md](./build_linux.md)**；安装后运维见 **[maintenance.md](./maintenance.md)**。

---

## 目录结构（AUR 侧）

维护目录示例：`~/aur-packages/micdn`

| 文件 | 作用 |
|------|------|
| `PKGBUILD` | 版本、依赖、构建与安装规则 |
| `.SRCINFO` | 由 `makepkg --printsrcinfo` 生成，推送 AUR 时必填 |
| `micdn.install` | 安装/升级/卸载钩子（systemd、目录权限、首次复制配置） |
| `micdn.sysusers` | 创建 `beangle` 组与 `micdn` 用户 |
| `micdn.tmpfiles` | 创建 `/var/cache/micdn`、`/var/lib/micdn`、`/var/log/micdn` 等 |

上游 tag 内自带：

- `scripts/package/micdn.xml` → 安装为 `/usr/share/micdn/micdn.xml.default`
- `scripts/package/micdn.service` → `/usr/lib/systemd/system/micdn.service`

`micdn.sysusers`、`micdn.tmpfiles` **不在**上游 tag 中，作为 AUR 本地文件列入 `source`。

---

## 前置条件

在 **Arch Linux**（或装齐 `makepkg` 的环境）上：

```bash
sudo pacman -S --needed base-devel git ldc dub curl zlib openssl
```

首次配置 AUR 远程：

```bash
cd ~/aur-packages/micdn
git remote add aur ssh://aur@aur.archlinux.org/micdn.git   # 若尚未添加
```

发布新版本前，确认 GitHub 上已有对应 tag（例如 `v0.2.3`）：

```bash
git ls-remote https://github.com/beangle/micdn.git refs/tags/v0.2.3
```

---

## 发布流程（顺序）

```
1. 修改 PKGBUILD / micdn.install 等
        ↓
2. updpkgsums          # 更新本地 source 的 sha256
        ↓
3. makepkg --printsrcinfo > .SRCINFO
        ↓
4. makepkg -s          # 本地试构建
        ↓
5. git commit && git push aur master
```

### 1. 修改 `PKGBUILD`

至少更新：

- `pkgver`（与 `dub.json` / GitHub tag 一致）
- `source` 中 git tag：`git+...#tag=v${pkgver}`
- 若仅修复打包脚本、未改上游：`pkgrel` 加 1

当前 `source` 约定：

```bash
source=(
  "git+https://github.com/beangle/micdn.git#tag=v${pkgver}"
  "micdn.install"
  "micdn.sysusers"
  "micdn.tmpfiles"
)
```

说明：

- **`install=micdn.install`**：安装脚本由 makepkg 从 PKGBUILD 同目录加载；列入 `source` 是为了 `updpkgsums` 校验与版本管理一致。
- **git 源码**：`sha256sums` 对应项为 `SKIP`。
- **本地三个文件**：`updpkgsums` 会写入真实 sha256。

### 2. 生成 checksum

在 AUR 目录执行：

```bash
cd ~/aur-packages/micdn
updpkgsums
```

仅手动计算时：

```bash
sha256sum micdn.install micdn.sysusers micdn.tmpfiles
```

`sha256sums` 数组顺序必须与 `source` 一一对应：

```bash
sha256sums=('SKIP' '<install的hash>' '<sysusers的hash>' '<tmpfiles的hash>')
```

### 3. 生成 `.SRCINFO`

```bash
makepkg --printsrcinfo > .SRCINFO
```

**不要**只改 `PKGBUILD` 而不更新 `.SRCINFO` 就 push；AUR 会校验二者一致。

### 4. 本地试构建

```bash
makepkg -s --noconfirm
```

成功产物：`micdn-<pkgver>-<pkgrel>-x86_64.pkg.tar.zst`。

可选：运行单测（`PKGBUILD` 内 `check()`，chroot 失败时可临时注释）：

```bash
makepkg -s --check --noconfirm
```

本地安装试跑：

```bash
makepkg -si --noconfirm
```

### 5. 提交并推送到 AUR

```bash
git add PKGBUILD .SRCINFO micdn.install micdn.sysusers micdn.tmpfiles
git commit -m "upg: micdn 0.2.3"
git push aur master
```

---

## 维护脚本示例

可保存为 `~/aur-packages/micdn/release-aur.sh`：

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

pkgver="${1:?用法: $0 <版本号，如 0.2.3>}"

git ls-remote https://github.com/beangle/micdn.git "refs/tags/v${pkgver}" | grep -q .

sed -i "s/^pkgver=.*/pkgver=${pkgver}/" PKGBUILD

updpkgsums
makepkg --printsrcinfo > .SRCINFO
makepkg -s --noconfirm

echo "构建完成。请检查后提交："
echo "  git add PKGBUILD .SRCINFO micdn.install micdn.sysusers micdn.tmpfiles"
echo "  git commit -m 'upg: micdn ${pkgver}'"
echo "  git push aur master"
```

用法：

```bash
chmod +x ~/aur-packages/micdn/release-aur.sh
~/aur-packages/micdn/release-aur.sh 0.2.3
```

---

## 用户安装与升级

从 AUR 安装（示例，使用 helper）：

```bash
yay -S micdn
# 或
paru -S micdn
```

升级后：

```bash
sudo systemctl daemon-reload
sudo systemctl restart micdn
journalctl -u micdn -b -n 30
```

### 配置文件

- 首次安装：`/etc/micdn/micdn.xml` 由 `micdn.xml.default` 复制生成。
- `PKGBUILD` 中 `backup=('etc/micdn/micdn.xml')`：升级时 pacman 会保留用户配置并生成 `.pacsave` / `.pacnew`（若有冲突）。
- **v0.2.3 起** www `<doc>` 格式变更（`location` + 子元素 → `name` + `npm|dir|zip` 属性，可选 `try-file`）。升级包不会自动改配置，需对照 [release-v0.2.3.md](./release-v0.2.3.md) 手动迁移。

### 离线安装静态资源（0.2.3+）

```bash
sudo -u micdn micdn -f /etc/micdn/micdn.xml mount www
sudo -u micdn micdn -f /etc/micdn/micdn.xml mount static
```

---

## 与 RPM 打包的差异

| 项目 | RPM（`build_rpm.sh`） | AUR（`PKGBUILD`） |
|------|------------------------|-------------------|
| 用户/目录 | `%pre` + spec 内 mkdir/chown | `micdn.sysusers` + `micdn.tmpfiles` + `micdn.install` |
| 默认配置 | `/usr/share/micdn/micdn.xml.default` | 同左 |
| systemd unit | 来自上游 `scripts/package/micdn.service` | 同左 |
| changelog | 读上游 `CHANGELOG.md` | AUR 提交信息 / 用户自行查阅上游 Release |

---

## 常见问题

**Q：`makepkg` 报 source 校验失败**

本地 `micdn.install` 等改过后未跑 `updpkgsums`，或 `sha256sums` 与 `source` 顺序不一致。

**Q：构建时找不到 `micdn.sysusers`**

应使用 `"$srcdir/micdn.sysusers"` 安装，且文件须与 `PKGBUILD` 同目录并列入 `source`；不要写 `scripts/package/micdn.sysusers`（上游 tag 无此路径）。

**Q：chroot 内 `check()` / `dub test` 失败**

可在 `PKGBUILD` 中临时注释 `check()` 再发布，或在本机 `makepkg --nocheck` 验证构建；建议在开发机上游仓库先 `dub test --config=unittest`。

**Q：升级后服务起不来**

```bash
journalctl -u micdn -b -n 50
```

v0.2.3 启动失败会输出 `micdn: ...` 到 stderr；配置/XML 错误退出码为 2，systemd 不会无限重启。
