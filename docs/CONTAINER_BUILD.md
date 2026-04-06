# 容器镜像构建说明（Podman）

本文说明如何用 **Podman** 构建 micdn 的 **Alpine（musl）** OCI 镜像：基本命令、**版本标签**、**apk / dub 缓存** 与常见问题。

**网络与代理：** 是否使用 HTTP 代理由**宿主机外部环境**决定；主要影响**首次从仓库拉取** `FROM alpine:…` 对应的基础镜像。基础镜像已在本地后，构建阶段通过 apk、dub 拉依赖时，一般可走**正常公网或国内镜像**（Dockerfile 内 apk 源已固定为华为云），**通常不再需要代理**。需要在拉镜像时走代理时，在运行 `podman build` 的 shell 里设置环境变量，见下文 **Shell 设置代理（示例）**。

根目录 **`Dockerfile`** 即为 **Alpine 多阶段** 定义；**不要**在宿主机 glibc 下编好二进制再拷进 Alpine。

---

## 前置条件

- 已安装 **Podman**（建议 **4.x 及以上**）。
- 在项目根目录（含 `Dockerfile`、`dub.json`、`src/`）执行下列命令。
- 推荐用 **`scripts/build_image.sh`**：构建前 **`dub fetch`**，**`--squash`**，并挂载 **`~/.dub` → `/root/.dub`**、**`~/.cache/alpine-apk` → `/var/cache/apk`**（apk 包持久化，与 dub 同理）。环境变量 **`ALPINE_APK_CACHE`** 可改 apk 缓存目录。

---

## Shell 设置代理（示例）

仅在**首次拉取**基础镜像（或访问容器仓库需要代理）时使用；代理地址、端口请换成你本机或网关的实际值。

```bash
export HTTP_PROXY=http://192.168.31.123:7897
export HTTPS_PROXY=http://192.168.31.123:7897
export NO_PROXY=localhost,127.0.0.1,::1

./scripts/build_image.sh
```

说明：

- `HTTP_PROXY` / `HTTPS_PROXY` 一般为 **`http://主机:端口`**（常见 HTTP 代理同样转发 HTTPS 流量）。
- `NO_PROXY` 列出不走代理的地址，避免本机或内网请求误走代理。
- 基础镜像拉取成功后，若后续构建不再需要代理，可在**新的 shell** 中执行构建，或执行 `unset HTTP_PROXY HTTPS_PROXY NO_PROXY`。

---

## 基本构建

```bash
./scripts/build_image.sh
```

脚本内已包含 **`podman build --squash`**，从 **`dub.json`** 读取 **`version`**，**仅**打上 **`micdn:<version>`**，不接受命令行改镜像名或 tag。需要 **`--no-cache`** 等时，可设置环境变量 **`PODMAN_BUILD_EXTRA`**（例如 **`PODMAN_BUILD_EXTRA=--no-cache ./scripts/build_image.sh`**）；推送到私有仓库请在构建后 **`podman tag`** / **`podman push`**。

若手写 `podman build`，建议同样加上 **`--squash`**，并务必带上 **`~/.dub`** 与 **`/var/cache/apk`** 的挂载（见下文）。

---

## 运行镜像

```bash
podman run --rm -p 8888:8888 micdn:0.2.0
```

可选数据持久化：

```bash
podman run --rm -p 8888:8888 \
  -v micdn-cache:/var/cache/micdn \
  -v micdn-data:/var/lib/micdn \
  micdn:0.2.0
```

镜像入口脚本 `scripts/container/entrypoint.sh`（构建时 COPY 为 `/entrypoint.sh`）会在启动时把上述目录 **`chown` 为 `micdn`**，避免命名卷/绑定挂载默认属主为 root 时出现 **`…/asset: Operation not permitted`**（进程无法对目录 `chmod` / 创建子目录）。若仍遇权限问题，可对卷追加 Podman 的 **`U`** 选项（将卷内容属主改为与容器进程一致），例如：

```text
-v micdn-cache:/var/cache/micdn:U -v micdn-data:/var/lib/micdn:U
```

---

## 缓存与重复构建

- **`/var/cache/apk`**：由 **`scripts/build_image.sh`** 挂载 **`ALPINE_APK_CACHE`（默认 `~/.cache/alpine-apk`）→ `/var/cache/apk`**，**builder** 与 **runtime** 两次 `apk add` 共用同一宿主机目录；**不再**使用 BuildKit 对 apk 的匿名 cache mount。
- **`dub`**：依赖放在 **`$DUB_HOME`（`/root/.dub`）**。脚本会在 **`podman build` 之前**于仓库根目录执行 **`dub fetch`**，并 **`-v $HOME/.dub:/root/.dub`**；**Dockerfile** 内**只** **`dub build`**。

### 宿主机 `dub fetch` + 挂载 `~/.dub`

- **无本机 `dub` 时**（如部分 CI）：设置 **`SKIP_DUB_FETCH=1`** 可跳过宿主机 `dub fetch`；仍会挂载 **`~/.dub`**（可为空，依赖完全在容器内下载）。
- **注意**：容器内 `dub` 可能对**主机** `~/.dub` **有写权限**，仅在本机信任环境使用。
- **手写**等价命令：`podman build --squash -v "$HOME/.dub:/root/.dub" -v "$HOME/.cache/alpine-apk:/var/cache/apk" -f Dockerfile …`（需自行先 `dub fetch`）。
- **不便用 `-v` 时**：仍可用 **`scripts/container/host-dub-cache/`** + **`COPY`**（见 **`Dockerfile`** 注释与 **`.gitignore`**）。

- **若手写 `podman build` 且不加 `-v "$HOME/.dub:/root/.dub"`**：`dub` 会把依赖写进**镜像层**，镜像会异常臃肿；请始终用 **`scripts/build_image.sh`** 或等价挂载。

### `apk` 缓存目录（`~/.cache/alpine-apk`）

**`./scripts/build_image.sh`** 会 **`mkdir -p`** 并挂载 **`${ALPINE_APK_CACHE:-$HOME/.cache/alpine-apk}:/var/cache/apk`**。多次构建时 **`.apk`** 留在该目录。

**apk-tools v3（Alpine 3.23+）**：默认**只**在 **`/var/cache/apk`** 里保留仓库索引（**`APKINDEX.*.tar.gz`**），安装时下载的 **`.apk`** 默认**不**写入缓存。**`Dockerfile`** 已在 **`apk add`** 上加了 **`--cache-packages`**，才会把包副本写入挂载目录，供下次构建复用。

- **手写**等价：`podman build --squash -v "$HOME/.dub:/root/.dub" -v "$HOME/.cache/alpine-apk:/var/cache/apk" -f Dockerfile -t micdn:0.2.0 .`（版本与 **`dub.json`** 一致）
- **构建若不加 `-v …:/var/cache/apk`**：`apk` 会把包装进**镜像层**或反复拉取，**请勿**无挂载构建。

- 若每次仍大量重新下载 **apk** / **dub**：
  - 使用了 **`podman build --no-cache`**：会重做所有层；**宿主机** **`~/.cache/alpine-apk`** 与 **`~/.dub`** 目录仍保留，应**仍**复用已下载文件。
  - 使用了 **`--pull` / `--pull-always`**：会拉新基础镜像，可能使后续层失效。
  - **改了** `apk add` / `dub build` **所在 `RUN` 之上的** Dockerfile（含 `FROM`、`sed`、前面的 `COPY` 等）：该 `RUN` 会重新执行；**apk 包**仍应命中 **`~/.cache/alpine-apk`** 与 **`~/.dub`** 中的文件。
  - **误以为**在下载：有时 **`apk`** 只是在更新 **索引（APKINDEX）** 或校验，体积大的 `.apk` 已命中缓存时输出仍可能像「在忙」。
  - **`apk add --no-cache`**：会清空 **`/var/cache/apk`**，与**持久挂载**冲突；**`Dockerfile`** 使用 **`apk add`（无 `--no-cache`）**。

### 多次构建仍能看到 APK 相关流量（不一定表示 cache 没生效）

- **索引**：`apk` 仍可能对镜像站发起 **HTTPS** 请求，拉取或核对 **APKINDEX**（体积通常远小于 **llvm**、**sqlite-dev** 等大包）。
- **两阶段**：**builder** 与 **runtime** 各有 **一次** `apk add`；若两层都执行，**各自**都可能与仓库通信（索引、元数据）。
- **层缓存未命中**：若 **`FROM`**、**`sed` 换源**、**`apk` 包列表** 等改动，对应 **`RUN`** 会**整段重跑**；**宿主机** **`~/.cache/alpine-apk`** 仍应复用已下载的 **`.apk`**，但**索引**与校验仍可能产生流量。
- **排查**：看构建输出里该 **`RUN`** 是否出现 **CACHED**；若**未改** Dockerfile 相关层，却仍出现**长时间**大下载，再试**临时去掉** **`--squash`** 对比（仅作排查）。

### 合并层（`--squash`）

**`scripts/build_image.sh` 已默认带上 `--squash`**，一般无需再手写。

若需**手动**执行或把**基础镜像层也**压成单层，可试 **`--squash-all`**（更慢、更占资源，按需）：

```bash
mkdir -p "$HOME/.cache/alpine-apk"
podman build --squash-all \
  -v "$HOME/.dub:/root/.dub" \
  -v "$HOME/.cache/alpine-apk:/var/cache/apk" \
  -f Dockerfile -t micdn:0.2.0 .
```

若 **`--squash`** 与 **`podman build`** 行为异常，可暂时去掉 `--squash` 或对脚本做本地修改。

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

## apk 源与基础镜像

`Dockerfile` 内已把 **apk 源固定为华为云**（`https://mirrors.huaweicloud.com/alpine`），构建时**无需**再传 `APK_MIRROR`。

**首次**拉取 `FROM alpine:3.23` 失败时，按 **Shell 设置代理（示例）** 设置环境变量，或先 `podman pull alpine:3.23`；本地已有基础镜像后，一般仍用 **`./scripts/build_image.sh`** 即可。

**说明：** `dub.json` 里 `versions`、`subConfigurations`（如 `vibe-stream:tls` → notls）对镜像构建生效；若某依赖在 musl 上编译失败，再针对该依赖排查（多为 C 库或 OpenSSL）。

---

## 相关文件


| 文件                      | 说明                  |
| ----------------------- | ------------------- |
| `Dockerfile`            | **Alpine（musl）** 多阶段镜像定义 |
| `scripts/container/micdn.xml` | 容器默认配置，COPY 进镜像（监听 `0.0.0.0`，路径为容器内绝对路径） |
| `scripts/container/entrypoint.sh` | 启动时修正数据目录属主，再以 `micdn` 运行 |
| `scripts/package/micdn.xml` | deb/rpm 安装用配置（与容器版不同，如监听 `127.0.0.1`、`~/` 路径） |
| `scripts/package/micdn.service` | systemd 单元，供 **`build_deb.sh`** / **`build_rpm.sh`** 打包 |
| `scripts/build_image.sh` | Podman 构建镜像（默认带 `--squash`） |
| `scripts/build_deb.sh` | 构建 Debian **`.deb`**（需 `dpkg-deb`、`fakeroot`） |
| `scripts/build_rpm.sh` | 构建 **`.rpm`**（需 `rpmbuild`、`fakeroot`） |
| `docs/BUILD_Windows.md` | Windows 原生 dub 构建说明 |

