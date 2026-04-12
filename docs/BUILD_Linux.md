# Linux 构建说明

本文说明在 **Linux 宿主机**上安装依赖、编译 micdn，以及按发行版选择 **`scripts/build_*.sh`** 打包。工具链需满足 `dub.json` 中的 `toolchainRequirements`（**dub ≥ 1.34**、**LDC ≥ 1.32** 等）。

Blob 在 Linux 上使用 **`user.*` 扩展属性** 存元数据；请在 **Linux** 上跑完整功能与单测。

---

## 仅编译可执行文件（开发/调试）

在仓库根目录执行：

```bash
dub fetch    # 可选，预先拉取依赖
dub build
```

产物为 **`target/micdn`**（默认 debug）。发布级优化与打包脚本一致时，使用：

```bash
dub build --build=release-nobounds --compiler=ldc2
```

**常见依赖（各发行版包名略有差异）：**

| 用途 | Fedora / RHEL 系 | Debian / Ubuntu |
|------|------------------|-----------------|
| D 编译器（`ldc2`） | `ldc` | `ldc` |
| 构建工具 | `dub` | `dub` |
| 链接 C 库等 | `gcc`、`glibc-devel`、`zlib-devel`、`openssl-devel` | `build-essential`、`zlib1g-dev`、`libssl-dev` |

Fedora 示例：

```bash
sudo dnf install ldc dub gcc zlib-devel openssl-devel
```

Debian/Ubuntu 示例：

```bash
sudo apt update
sudo apt install ldc dub build-essential zlib1g-dev libssl-dev
```

若发行版仓库中 **LDC/dub 版本偏旧**，可从 [LDC 发布页](https://github.com/ldc-developers/ldc/releases) 或 [D 官网](https://dlang.org/download.html) 安装较新版本后再执行 `dub build`。

---

## 打包脚本与发行版对应关系

| 脚本 | 产物 | 典型环境 |
|------|------|----------|
| **`scripts/build_rpm.sh`** | `target/micdn-*.x86_64.rpm` | Fedora / RHEL / openSUSE 等 **RPM** 系 |
| **`scripts/build_srpm.sh`** | `target/micdn-*.src.rpm` | 同上；用于 mock/koji 或 `rpmbuild --rebuild` 再出二进制 RPM |
| **`scripts/build_deb.sh`** | `target/micdn_*_amd64.deb` | Debian / Ubuntu 等 **deb** 系 |
| **`scripts/build_image.sh`** | OCI 镜像 `micdn:<version>` | 已安装 **Podman**（见 **[CONTAINER_BUILD.md](./CONTAINER_BUILD.md)**） |

所有脚本均在**仓库根目录**下执行（路径含 `dub.json`、`scripts/`）。

---

## Fedora / RHEL / openSUSE（RPM）：`build_rpm.sh` / `build_srpm.sh`

### 安装系统软件包

脚本会先执行 **`dub build --build=release-nobounds --compiler=ldc2`**，再调用 **rpmbuild** 等，建议安装：

```bash
sudo dnf install ldc dub gcc zlib-devel openssl-devel \
  rpm-build fakeroot gzip binutils
```

- **RHEL / CentOS Stream**：若仓库无较新 **ldc/dub**，需启用 **EPEL**、**CodeReady** 或自行安装 LDC/dub 后再跑脚本。
- **openSUSE**：可用 **`zypper install`** 安装同名或相近包（如 `ldc2`、`dub`、`rpm-build`）。

### 构建二进制 RPM

```bash
cd /path/to/micdn
./scripts/build_rpm.sh
```

已存在同名 RPM 时会跳过；强制重建：

```bash
./scripts/build_rpm.sh -f
```

### 仅生成源码 SRPM（`build_srpm.sh`）

宿主机需 **`gzip`、`rpmbuild`、`tar`**（脚本内不执行本地 `dub build`，但 **SRPM 内 `%build` 会在重编时执行 dub**）：

```bash
sudo dnf install gzip rpm-build tar
./scripts/build_srpm.sh
```

---

## Debian / Ubuntu（deb）：`build_deb.sh`

### 安装系统软件包

```bash
sudo apt update
sudo apt install ldc dub build-essential zlib1g-dev libssl-dev \
  dpkg-dev fakeroot binutils
```

### 构建 deb

```bash
cd /path/to/micdn
./scripts/build_deb.sh
```

强制重建：`./scripts/build_deb.sh -f`。

### 安装生成的 deb

推荐用 **`dpkg`** 直接安装（不依赖 `_apt` 能否进入你的家目录）：

```bash
sudo dpkg -i target/micdn_*_amd64.deb
sudo apt-get install -f   # 若有依赖未满足，补全后配置软件包
```

或使用 **`apt`**，但 **`apt install ./path/to.deb`** 会由用户 **`_apt`** 读取该路径。若 deb 放在 **`$HOME`** 下，而家目录权限为 **`700`**（默认常见），**`_apt` 无法进入该路径**，会出现类似警告：

```text
Download is performed unsandboxed as root as file '.../target/micdn_....deb' couldn't be accessed by '_apt'. Permission denied
```

这不影响正常安装，只是 apt 无法用沙箱下载/校验该本地文件。可选处理方式：

1. **把 deb 拷到全局可读路径再装**（推荐，警告可消失）：

   ```bash
   cp target/micdn_*_amd64.deb /tmp/
   sudo apt install /tmp/micdn_*_amd64.deb
   ```

2. **继续用 `sudo dpkg -i`** 指向 `~/.../target/` 下的文件（通常无上述警告）。

---

## 容器镜像（任意带 Podman 的 Linux）

不依赖宿主机 glibc 与 Alpine 一致的二进制，使用 **Podman** 在容器内构建，见 **[CONTAINER_BUILD.md](./CONTAINER_BUILD.md)**。

```bash
./scripts/build_image.sh
```

---

## 输出位置与版本号

- 可执行文件默认在 **`target/micdn`**。
- RPM/deb/SRPM 文件名中的版本来自根目录 **`dub.json`** 的 **`"version"`** 字段。
- 若脚本提示缺少 **`dpkg-deb` / `rpmbuild` / `strip`** 等，按上文补齐对应包后重试。
