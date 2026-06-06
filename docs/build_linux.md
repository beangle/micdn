# Linux 构建说明

本文说明在 **Linux 宿主机**上安装依赖、编译 micdn，以及按发行版选择 **`scripts/build_*.sh`** 打包。工具链需满足 `dub.json` 中的 `toolchainRequirements`（**dub ≥ 1.34**、**LDC ≥ 1.32** 等）。

Blob 在 Linux 上使用 **`user.*` 扩展属性** 存元数据；请在 **Linux** 上跑完整功能与单测。

由 **deb/rpm** 安装并由 **systemd** 托管时，普通用户如何将账号加入 **`beangle`** 组、理解数据目录 **`2775` / 组可写** 及编辑配置的方式，见 **[maintenance.md](./maintenance.md)**。

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

## druntime / Phobos 的静、动态链接

micdn 的 **`dub.json` 与打包脚本不指定** druntime、Phobos 的链接方式；与 **`dub build --build=release-nobounds --compiler=ldc2`** 配套使用时，**由本机 LDC 环境决定**：

| 因素 | 说明 |
|------|------|
| **`ldc2.conf`** | 发行版 ldc 包常在 `/etc/ldc2.conf` 注入 `-link-defaultlib-shared`，默认可执行文件**动态**链 druntime（如 Fedora）。官方 [LDC 预编译包](https://github.com/ldc-developers/ldc/releases) 通常默认可执行文件**静态**链 druntime。 |
| **是否提供 `.a`** | 若系统 ldc 仅安装 shared 库（如 Fedora `ldc-libs` 只有 `libdruntime-ldc-shared.so.*`），即使显式 `-link-defaultlib-shared=false` 也会链接失败；此时只能动态链，目标机需安装对应 ldc 运行时包。 |

构建完成后可用 **`ldd target/micdn`** 查看：若出现 `libdruntime-ldc-shared.so`、`libphobos2-ldc-shared.so`，则二进制**动态**依赖 ldc 运行时；若无，则 druntime 已**静态**编入可执行文件，目标机通常无需安装 ldc。

rpm/deb 包的 **`Requires` / `Depends` 目前仅声明 `curl`**；若你在动态链环境下打包，请自行确认目标机是否已具备与构建时 soname 一致的 ldc 运行时库，必要时在发布说明或包依赖中补充。

---

## 打包脚本与发行版对应关系

| 脚本 | 产物 | 典型环境 |
|------|------|----------|
| **`scripts/build_rpm.sh`** | `target/micdn-*.x86_64.rpm` | Fedora / RHEL / openSUSE 等 **RPM** 系 |
| **`scripts/build_srpm.sh`** | `target/micdn-*.src.rpm` | 同上；用于 mock/koji 或 `rpmbuild --rebuild` 再出二进制 RPM |
| **`scripts/build_deb.sh`** | `target/micdn_*_amd64.deb` | Debian / Ubuntu 等 **deb** 系 |
| **AUR `PKGBUILD`** | `micdn-*.pkg.tar.zst` | **Arch Linux**（维护与发布见 **[build_aur.md](./build_aur.md)**） |
| **`scripts/build_image.sh`** | OCI 镜像 `micdn:<version>` | 已安装 **Podman**（见 **[container_build.md](./container_build.md)**） |

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

不依赖宿主机 glibc 与 Alpine 一致的二进制，使用 **Podman** 在容器内构建，见 **[container_build.md](./container_build.md)**。

```bash
./scripts/build_image.sh
```

---

## 输出位置与版本号

- 可执行文件默认在 **`target/micdn`**。
- RPM/deb/SRPM 文件名中的版本来自根目录 **`dub.json`** 的 **`"version"`** 字段。
- 若脚本提示缺少 **`dpkg-deb` / `rpmbuild` / `strip`** 等，按上文补齐对应包后重试。
