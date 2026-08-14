# micdn

轻量 CDN / 静态资源服务：Maven、npm、WebJar/本地静态包、WWW 文档站点与 Blob 存储（含可选 S3 兼容 API）。配置驱动，单进程 HTTP。

**License:** GPLv3 · **Version:** 0.3.2

## 功能

| 服务 | 说明 |
|------|------|
| **static** | 从 Maven GAV（WebJar）、npm 包或本地目录部署前端资源，按 bundle 提供 |
| **www** | SPA/文档站：npm / zip；支持 `try-file`；zip 可 `auto-deploy`（Linux inotify） |
| **maven** / **npm** | 本地缓存 + 上游 remote 拉取 |
| **blob** | 对象存储；可选 S3 兼容接口 |
| **admin** | localhost 只读指标 `/admin/metrics`、配置查看与 reload |

路径属性支持 `${micdn.home}` 与 `~` 展开。

## 快速开始

```bash
# 依赖：ldc、dub（见 docs/build_linux.md）
dub build --build=release-nobounds --compiler=ldc2

./target/micdn -f resources/micdn.xml          # 启动 HTTP
./target/micdn -f /etc/micdn/micdn.xml resolve # 解析并部署全部 www/static（不启动 HTTP）
./target/micdn -f /etc/micdn/micdn.xml deploy www manual
./target/micdn -f /etc/micdn/micdn.xml deploy static bootstrap --force
./target/micdn -f /etc/micdn/micdn.xml clean --yes # 清除 www/static 部署目录（交互终端下会逐项确认；maven/npm 缓存与 blob 数据不清理）
```

`-f` 可为本地文件、目录（使用 `DIR/micdn.xml`）或 URL（下载到 `~/micdn.xml`）。

## 配置示例

```xml
<micdn home="/var/lib/micdn" listen="127.0.0.1:8080">
  <maven base="${micdn.home}/maven">
    <remote url="https://repo1.maven.org/maven2/" />
  </maven>
  <npm base="${micdn.home}/npm">
    <remote url="https://registry.npmmirror.com" />
  </npm>
  <static base="/var/cache/micdn/asset">
    <bundle name="bootstrap">
      <jar gav="org.webjars:bootstrap:4.6.1" />
    </bundle>
    <bundle name="local">
      <dir location="/srv/static/local" />
    </bundle>
  </static>
  <www base="/var/cache/micdn/www">
    <doc name="manual" zip="${micdn.home}/releases/manual.zip"
         inner="dist" try-file="index.html" auto-deploy="true" />
  </www>
  <blob base="${micdn.home}/blob" maxSize="50M">
    <bucket name="local" key="..." />
  </blob>
</micdn>
```

`<static>` 的 bundle 支持两类 provider：`<jar>`/`<npm>` 解压部署并构建**发布期索引**（请求期 0 stat，强制 gzip 预压缩）；`<dir>` 以**符号链接**挂载源目录，**不构建索引**（请求期逐次 stat），gzip 完全忽略（不发送也不生成，避免把源目录中用户自带的 `.gz` 误当预压缩内容）。

更完整的样例见 [`resources/micdn.xml`](resources/micdn.xml)。

## gzip 预压缩

static / www 部署的文本类静态资源（`js`、`css`、`html`、`svg`、`json`、`xml`、`txt`、`map` 等）采用「**部署期预压缩**」的 sidecar 模式：

- 压缩发生在部署期：www doc 默认参与（`auto-gzip` 开关），asset 非 `<dir>` bundle 强制启用；`precompressDir` 遍历目录生成 `path.gz`（sidecar 已存在则跳过），无后台压缩线程、无请求期竞争。预压缩只在**实际解压部署**时执行——manifest 快路径跳过解压（源未变）时同样跳过，重复启动不扫描、不补齐缺失的 sidecar。
- 请求线程只读：客户端 `Accept-Encoding` 接受 gzip 且 `path.gz` 存在时直接发送预压缩内容（`Content-Encoding: gzip`、`Vary: Accept-Encoding`）；sidecar 大小随发布期索引同趟登记（`gzSize`），请求期 0 stat。
- `Accept-Encoding` 判定为简化实现：面向现代浏览器，仅按子串识别 `gzip`（大小写不敏感），不处理 `q=0` 拒绝与 `*` 通配等完备语义。
- 压缩写 `tmp` 后原子 `rename`；仅当压缩后确实更小才落盘，小于 1KB 或超过 8MB 的文件不压缩（小文件 gzip 固定开销使其不划算，超限文件避免大内存分配）。
- 已压缩格式（图片、字体、`.gz`/`.br` 等）不生成 sidecar；`Range` 请求不返回 gzip；asset 不支持逗号拼接 URI（`/a/b,c.js`）。
- www doc 仅支持 `npm`/`zip`（无 `<dir>` 挂载），默认全部参与 gzip 预压缩；可按 doc 设 `auto-gzip="false"` 完全关闭（不发送已有 `.gz` 也不生成）。asset 的 `<dir>` dyna bundle 完全忽略 gzip（不发送也不生成，避免把源目录中用户自带的 `.gz` 文件误当预压缩内容，也避免写入源目录）。

### 约定与取舍

- 超过 8MB 或小于 1KB 的文件不压缩（`src/micdn/web/gzip.d` 中 `maxGzipFileSize` / `minGzipFileSize`）。这是一个保护性区间，而非性能优化目标：
  - 压缩在部署期顺序执行，超大文件会拖慢当次部署的收尾阶段；
  - 当前实现为整文件读入 + 整块压缩，峰值内存约为源文件的 2 倍，该上限保证 daemon 内存有界；
  - 图片、字体等大文件本就不在白名单内，超过 8MB 的文本型资源（巨型 JSON、source map）属于非典型场景，为其生成 sidecar 的磁盘放大收益有限；
  - 小文本（如几十字节的 JS/CSS）gzip 固定开销约 18 字节，压缩后往往不更小，下限避免无收益的生成。
- 典型前端静态资源（JS/CSS/HTML 等）远小于 8MB、远大于 1KB，该区间不影响正常部署；如需调整，直接修改 `minGzipFileSize` / `maxGzipFileSize` 即可（当前为硬编码，未做配置化）。

与上游中间件（nginx / varnish / haproxy）的缓存、压缩协作部署见 [docs/reverse_proxy.md](docs/reverse_proxy.md)。

## 运行时系统命令依赖（curl）

micdn 自身**不内嵌** TLS 与下载实现，远端拉取委托给宿主环境的 `curl`（`src/micdn/web/file.d` 的 `curlDownload`）。这是刻意的设计取舍：

- **可移植性**：不绑定特定版本或来源的 OpenSSL / TLS 库（部分系统没有高版本 OpenSSL），TLS 能力随宿主 `curl` 走，跨发行版（老版本 RHEL/CentOS、Debian、Alpine 等）行为一致；
- **体积与性能**：`curl` 单二进制小、依赖轻（相对 wget），且是几乎所有发行版的基础组件，无需随 micdn 分发 TLS 库；
- **失败可观测**：下载失败按 curl 退出码记日志（`Download failed … (curl exit N)`）；先写 `.part` 临时文件、成功才 rename，避免残留半包。

运行时外部命令依赖**仅 `curl` 一个**：远端下载（maven/npm/asset 及远程配置文件）委托宿主 `curl`；tgz（npm 包）解压已内置——`std.zlib` 解 gzip + 自实现 tar 解析（`src/micdn/fs/tar.d` 的 `extractTgz`），不再依赖宿主 `tar` 命令。打包侧相应声明 `Depends: curl` / `depends=('curl')`（见 [docs/build_linux.md](docs/build_linux.md)、[docs/build_aur.md](docs/build_aur.md)）。对外提供 HTTP 服务、读取本地缓存与已部署内容均不依赖 `curl`。

注意区分：Arch 的 `pacman` 更新走 libalpm 内置的 libcurl / 自带下载器，**不依赖** `curl` 命令本身；但 micdn 的远端拉取需要系统里存在 `curl` 命令。

## 安装与运维

| 文档 | 内容 |
|------|------|
| [docs/build_linux.md](docs/build_linux.md) | Linux 编译、RPM / deb / SRPM 打包 |
| [docs/container_build.md](docs/container_build.md) | Podman / OCI 镜像 |
| [docs/build_aur.md](docs/build_aur.md) | Arch AUR |
| [docs/maintenance.md](docs/maintenance.md) | systemd、`micdn`/`beangle` 权限、resolve/deploy、auto-deploy |
| [docs/reverse_proxy.md](docs/reverse_proxy.md) | nginx / varnish 缓存、haproxy 压缩等协作部署 |
| [docs/stress_test.md](docs/stress_test.md) | 压测复测指南：环境、样例、场景与结果比较 |
| [docs/release-v0.3.1.md](docs/release-v0.3.1.md) | 当前版本说明 |

打包脚本（每次默认 `dub clean` + 清空 `target/` 后全量构建）：

```bash
./scripts/build_rpm.sh
./scripts/build_deb.sh
./scripts/build_image.sh
```

## 开发

```bash
dub test
```

要求：dub ≥ 1.34、LDC ≥ 1.32（见 `dub.json`）。Blob 元数据依赖 Linux `user.*` 扩展属性，完整功能请在 Linux 上验证。
