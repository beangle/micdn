# 静态构建与可移植性说明

本文记录 micdn 的**全静态构建**方案与结论：**静态构建产出的 `micdn` 二进制是纯静态的，可在任意 x86_64 Linux 上直接运行**，不依赖宿主机的 curl、OpenSSL、musl 加载器。

---

## 结论

| 产物 | 链接方式 | 可移植性 |
|------|----------|----------|
| `dub build -c executable-static` 构建的 `micdn`（含 `Dockerfile.scratch` 产物） | **纯静态**：druntime/phobos + libcurl + OpenSSL + zlib 全部静态 | 任意 x86_64 Linux 可直接运行，无需安装 curl / OpenSSL |
| 本地默认 `dub build` 的 `target/micdn` | **动态链接**：依赖 `libdruntime-ldc-shared.so`、`libphobos2-ldc-shared.so`、`libz.so.1`、glibc 等 | 只能在构建它的系统上运行，拷贝到其他发行版会缺依赖 |

验证方式：

```bash
file target/micdn        # statically linked
readelf -d target/micdn  # 无 NEEDED 条目
ldd target/micdn         # 输出 "statically linked"
```

## 限制

- **架构**：目前为 x86_64 静态构建；支持 ARM 需另行交叉编译。
- **CA 证书**：HTTPS 需要证书文件（不是库），静态二进制不携带 CA bundle。常见发行版默认有 `/etc/ssl/certs/ca-certificates.crt`；精简系统可用 `SSL_CERT_FILE=/path/to/ca-certificates.crt` 指定（见下文）。
- **"任何 Linux"指发行版无关**，不是指任何 CPU 架构。
- **libc 选择**：全静态统一用 **musl**（`Dockerfile.scratch` 的 Alpine builder 提供）。glibc 静态链接存在已知问题（如 DNS 解析经 NSS 模块动态加载，全静态下极端精简系统可能解析失败），本方案不采用 glibc 静态方式。

---

## 构建环境与步骤

静态构建的产出与**构建环境**强相关：需要 musl 工具链与静态库齐备的环境，`dub build -c executable-static` 才能链接出纯静态产物。Fedora 等本机发行版默认缺少 musl 静态环境，不能直接构建，推荐用 `Dockerfile.scratch` 的容器环境（现成、可复现）。

### 构建环境要求

| 组件 | 说明 |
|------|------|
| musl 工具链 | Alpine 等提供（`Dockerfile.scratch` 基于 `alpine:3.23`） |
| LDC ≥ 1.32 + dub | `dub.json` 的 `toolchainRequirements` |
| 静态库 | `libcurl.a`、`libssl.a`、`libcrypto.a`、`libz.a`（`executable-static` 的 `lflags` 显式引用，见 `dub.json`） |
| 全静态链接 | `-link-defaultlib-shared=false -L-static` |

### 构建步骤

```bash
# 1. 静态库就绪后，直接构建（无需克隆 curl 源码）
dub build --config=executable-static --build=release-nobounds --compiler=ldc2

# 2. 瘦身并验证
strip --strip-unneeded target/micdn
file target/micdn        # statically linked
ldd target/micdn         # statically linked
```

### 环境准备：容器（Dockerfile.scratch，musl）

`./scripts/build_scratch.sh` 在 `alpine:3.23` builder 内完成全部环境准备与构建，是**获得 musl 全静态产物的现成途径**：

- builder 内**自编最小静态 libcurl**：Alpine 预编译的 `libcurl.a` 含 brotli/psl 等引用，`ld.lld` 链接会报 undefined symbol，因此改为 `autoreconf -fi && ./configure … && make -C lib` 自编，仅保留 OpenSSL+zlib 依赖——这是容器路径**需要 curl 源码**的原因。
- 构建前置：仓库根需有 **`.curl-src/`**（curl git 树，构建时执行 `autoreconf -fi` 生成 configure）。该目录体积较大，被 `.gitignore` 排除、**不随仓库分发**，首次构建前自行准备：

  ```bash
  git clone https://github.com/curl/curl.git .curl-src
  ```

  国内镜像（注意 gitee 有防爬认证，可能不稳定）：

  ```bash
  git clone https://gitee.com/mirrors/curl.git .curl-src
  ```

- 产物：镜像约 **21.2MB**（`/micdn` 约 20.97MB 全静态 + CA 证书），无 shell / apk / 调试工具，连 musl loader 都不带。

---

## CA 证书（HTTPS）

- 静态二进制不内置 CA bundle；HTTPS 下载走 libcurl/OpenSSL 默认证书路径（通常 `/etc/ssl/certs/ca-certificates.crt`），可被 `SSL_CERT_FILE` / `CURL_CA_BUNDLE` 环境变量覆盖。
- 容器构建在 rootfs 中打包了 `ca-certificates.crt`，所以镜像内零外部依赖；只拷二进制出去时，宿主需自带证书或设置 `SSL_CERT_FILE`。

---

## 下载双后端（curl.d）

`src/micdn/web/curl.d` 通过编译开关切换下载实现，函数签名不变：

| 配置 | 开关 | 行为 |
|------|------|------|
| 默认 `dub build` | 无 | 调用宿主 `curl` 命令（需安装 curl） |
| `dub build -c executable-static` | `version(MicdnUseLibcurl)` | 静态链接 libcurl，不依赖宿主 curl/OpenSSL |

## 相关取舍记录

- **TLS 使用 `notls`**：micdn 本身是 HTTP CDN 服务，TLS 由反向代理处理，`subConfigurations` 中 `vibe-stream:tls: notls` 可避免全局静态 OpenSSL 带来的约 6MB 体积开销。
- **放弃 dub 包 `openssl-static` 依赖方案**：其预编译 `.a` 针对较新 glibc 构建，老系统有风险；且 configuration 内的 `subConfigurations` 曾触发 dub 1.41 配置被忽略的 bug。静态库改为在 `dub.json` 的 `executable-static` 中**显式写库路径**。
