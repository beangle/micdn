# 容器镜像构建说明（Docker / Podman）

本文说明如何构建 micdn 的 OCI 镜像：基本命令、**版本标签**、**HTTP/HTTPS 代理**，以及可选的 **Debian apt 国内镜像** 与常见问题。

基础镜像为 `**debian:trixie-slim`**，多阶段构建；详见项目根目录 `Dockerfile`。

---

## 前置条件

- 已安装 **Podman** 或 **Docker**（含 `docker build` / `docker buildx`）。
- Dockerfile 使用 BuildKit 语法（`RUN --mount=type=cache`）。使用 **Docker** 时建议启用 BuildKit，例如：
  - 环境变量：`export DOCKER_BUILDKIT=1`
  - 或在 `~/.docker/config.json` 中设置 `"features": { "buildkit": true }`
- 在项目根目录（含 `Dockerfile`、`dub.json`、`src/`）执行下列命令。

---

## 基本构建

```bash
podman build -t micdn .
```

默认标签为 `**latest**`（完整名称为 `micdn:latest`）。

---

## 指定版本标签（例如 0.2.0）

```bash
podman build -t micdn:0.2.0 .
```

同一次构建可打多个标签：

```bash
podman build -t micdn:0.2.0 -t micdn:latest .
```

---

## 构建时使用代理

若拉取基础镜像、`apt`、`dub`、git 等需经公司或本机代理，请通过 `**--build-arg**` 传入（与 Dockerfile 中 `ARG HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` 对应）：

```bash
podman build \
  --build-arg HTTP_PROXY=http://192.168.31.123:7890 \
  --build-arg HTTPS_PROXY=http://192.168.31.123:7890 \
  --build-arg NO_PROXY=localhost,127.0.0.1,.example.com \
  -t micdn:0.2.0 \
  .
```

**请注意：**

- 代理地址必须为完整 URL，例如 `http://主机:端口` 或 `https://主机:端口`，**不要**只写 `http` 或缺少 `://`，否则可能出现类似 `lookup http: no such host` 的错误。
- 仅在需要代理时传入；不需要时可省略，或先 `unset HTTP_PROXY HTTPS_PROXY` 再构建，避免错误的环境变量影响构建。

---

## 可选：Debian apt 国内镜像（加速或网络受限时）

`Dockerfile` 支持以 `**APT_MIRROR`**、`**APT_SECURITY_MIRROR**` 覆盖官方 `deb.debian.org` 源（**builder 与 runtime 两阶段都需传入**）。

**阿里云（HTTPS 示例）：**

```bash
podman build \
  --build-arg APT_MIRROR=https://mirrors.aliyun.com/debian \
  --build-arg APT_SECURITY_MIRROR=https://mirrors.aliyun.com/debian-security \
  -t micdn:0.2.0 \
  .
```

**清华：**

- `APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian`
- `APT_SECURITY_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian-security`

若出现 `**SSL connection failed` / `certificate verify failed`**（常见于 HTTPS 被拦截或证书链与容器内 CA 不一致），可改用 **HTTP** 镜像根（Debian apt 传统上允许以明文访问仓库，软件包仍有签名校验）：

```bash
podman build \
  --build-arg APT_MIRROR=http://mirrors.aliyun.com/debian \
  --build-arg APT_SECURITY_MIRROR=http://mirrors.aliyun.com/debian-security \
  -t micdn:0.2.0 \
  .
```

---

## 代理与 apt 镜像一并使用（示例）

```bash
podman build \
  --build-arg HTTP_PROXY=http://192.168.31.2:7890 \
  --build-arg HTTPS_PROXY=http://192.168.31.2:7890 \
  --build-arg NO_PROXY=localhost,127.0.0.1 \
  --build-arg APT_MIRROR=http://mirrors.aliyun.com/debian \
  --build-arg APT_SECURITY_MIRROR=http://mirrors.aliyun.com/debian-security \
  -t micdn:0.2.0 \
  .
```

按实际代理地址与是否需要 apt 镜像调整参数。

---

## 运行镜像

```bash
podman run --rm -p 8888:8888 micdn:0.2.0
```

可选数据持久化（见 `Dockerfile` 注释）：

```bash
podman run --rm -p 8888:8888 \
  -v micdn-cache:/var/cache/micdn \
  -v micdn-data:/var/lib/micdn \
  micdn:0.2.0
```

---

## 缓存与重复构建

- Dockerfile 中 `apt` 与 `dub` 使用 BuildKit **cache mount**，在相同机器上重复构建时可减少重复下载。
- 若每次仍大量重新下载，常见原因包括：使用 `--no-cache`、使用 `--pull`/`--pull-always` 导致缓存失效，或修改了 `apt`/`dub` 所在 `RUN` **之前**的任一层（含 `FROM`、`COPY` 等）。

---

## 查看镜像

```bash
podman images micdn
podman history micdn:0.2.0
podman inspect micdn:0.2.0
```

查看文件系统内容（若镜像内有 shell）：

```bash
podman run --rm -it micdn:0.2.0 sh
```

---

## 相关文件


| 文件                      | 说明                  |
| ----------------------- | ------------------- |
| `Dockerfile`            | 镜像定义、构建参数说明（注释）     |
| `docker/micdn.xml`      | 默认配置，COPY 进镜像       |
| `docs/BUILD_Windows.md` | Windows 原生 dub 构建说明 |


