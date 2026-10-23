# 构建与打包脚本

| 路径 | 用途 |
|------|------|
| `build_image.sh` | Podman 构建 OCI 镜像（Alpine / musl） |
| `build_deb.sh` | 构建 `.deb`（需 Debian 系或 `dpkg-deb`） |
| `build_rpm.sh` | 构建二进制 `.rpm`（需 `rpmbuild >= 4.14`、`fakeroot`；先 `dub clean` 再 release 构建） |
| `build_srpm.sh` | 构建源代码 `.src.rpm`（需 `rpmbuild`、`tar`；可用 `rpmbuild --rebuild` 在目标机重编） |
| `build_common.sh` | 打包共用：`dub clean`、清空 `target/`、`dub build --build=release-nobounds` |
| `stress_bench.sh` | 四场景吞吐压测（目录/文件/404/gzip，预热 + 多轮取中位，见 `docs/stress_test.md`） |
| `stress_mem.sh` | 多文件内存压测（自生成样例，c=50 多路径 + c=200 heavy，可选 `/admin/reclaim`） |
| `setup-windows.ps1` | Windows 下 dub / 依赖补丁 |
| `container/` | **仅镜像**：默认 `micdn.xml`、`entrypoint.sh`；可选本地 `host-dub-cache/`（见 `.gitignore`） |
| `package/` | **deb/rpm 与镜像共用**：面向 systemd 安装的 `micdn.xml`（与容器版不同）、reload 用 `micdn.conf`、`micdn.service` |

Arch Linux AUR 打包步骤见 **[docs/build_aur.md](../docs/build_aur.md)**（维护目录通常为 `~/aur-packages/micdn`）。

容器与原生安装的默认配置刻意分开放：`container/micdn.xml` 面向容器网络与路径；`package/micdn.xml` 面向本机用户与 `127.0.0.1`。

> **打包红线：`/etc/micdn/micdn.xml` 与 `/etc/micdn/micdn.conf` 是用户配置，任何安装包都不得删除或
> 覆盖。** 包内只放 `/usr/share/micdn/*.default` 模板；`%post`/`postinst` 只在目标文件不存在时生成；
> 不要把这两个路径写进 `%files`、`conffiles`，也不要在 `%preun`/`prerm`/`%postun`/`postrm` 里 `rm`。
> 卸载、重装、升级都必须保留原文件。
