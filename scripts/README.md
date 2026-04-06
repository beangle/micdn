# 构建与打包脚本

| 路径 | 用途 |
|------|------|
| `build_image.sh` | Podman 构建 OCI 镜像（Alpine / musl） |
| `build_deb.sh` | 构建 `.deb`（需 Debian 系或 `dpkg-deb`） |
| `build_rpm.sh` | 构建二进制 `.rpm`（需 `rpmbuild`、`fakeroot`；先本地 `dub build`） |
| `build_srpm.sh` | 构建源代码 `.src.rpm`（需 `rpmbuild`、`tar`；内含源码包与 spec，可用 `rpmbuild --rebuild` 在目标机重编） |
| `setup-windows.ps1` | Windows 下 dub / 依赖补丁 |
| `container/` | **仅镜像**：默认 `micdn.xml`、`entrypoint.sh`；可选本地 `host-dub-cache/`（见 `.gitignore`） |
| `package/` | **仅 deb/rpm**：面向 systemd 安装的 `micdn.xml`（与容器版不同）、`micdn.service` |

容器与原生安装的默认配置刻意分开放：`container/micdn.xml` 面向容器网络与路径；`package/micdn.xml` 面向本机用户与 `127.0.0.1`。
