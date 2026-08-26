# micdn

轻量 CDN / 静态资源服务：Maven、npm、WebJar/本地静态包、WWW 文档站点与 Blob 存储（含可选 S3 兼容 API）。配置驱动，单进程 HTTP。

**License:** GPLv3 · **Version:** 0.3.3

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

bundle 支持两类 provider：`<jar>`/`<npm>` 解压部署并构建发布期索引；`<dir>` 以符号链接挂载源目录、不构建索引（也不参与 gzip 预压缩）。更完整的样例见 [`resources/micdn.xml`](resources/micdn.xml)。

## gzip 预压缩

static / www 的文本类资源（js/css/html/svg/json 等）在**部署期**预压缩为 `path.gz` sidecar，请求期命中即直接发送（`Content-Encoding: gzip`、`Vary: Accept-Encoding`），无需请求期压缩：

- www doc 默认参与，可按 doc 设 `auto-gzip="false"` 关闭；asset 的 `<dir>` bundle 不参与（不生成也不发送，避免误用源目录自带的 `.gz`）。
- 小于 1KB 或超过 8MB 的文件，以及图片/字体等已压缩格式不生成 sidecar；`Range` 请求不返回 gzip。
- 与上游中间件（nginx / varnish / haproxy）的缓存、压缩协作部署见 [docs/reverse_proxy.md](docs/reverse_proxy.md)。

## 下载与 curl

远端下载（maven/npm/asset 与远程配置）统一由 `curlDownload` 完成，按编译开关选择实现（`src/micdn/web/curl.d`）：

| 构建方式 | 开关 | 下载实现 | 运行时依赖 |
|----------|------|----------|------------|
| `dub build` | 无 | 调用宿主 `curl` 命令 | 宿主需安装 curl |
| `dub build -c executable-static` | `version(MicdnUseLibcurl)` | 静态链接 libcurl | 不依赖宿主 curl/OpenSSL |

默认构建的运行时外部命令依赖**仅 `curl` 一个**（tgz 解压已内置，见 `src/micdn/fs/tar.d`），rpm/deb/AUR 打包相应声明 `Depends: curl`；静态构建产物适合容器与离线环境。下载先写 `.part` 临时文件、成功才改名，失败按 curl 退出码记日志。

## 安装与运维

| 文档 | 内容 |
|------|------|
| [docs/build_linux.md](docs/build_linux.md) | Linux 编译、RPM / deb / SRPM 打包 |
| [docs/container_build.md](docs/container_build.md) | Podman / OCI 镜像 |
| [docs/build_static_portable.md](docs/build_static_portable.md) | 全静态构建与可移植性说明 |
| [docs/build_aur.md](docs/build_aur.md) | Arch AUR |
| [docs/maintenance.md](docs/maintenance.md) | systemd、`micdn`/`beangle` 权限、resolve/deploy、auto-deploy |
| [docs/reverse_proxy.md](docs/reverse_proxy.md) | nginx / varnish 缓存、haproxy 压缩等协作部署 |
| [docs/stress_test.md](docs/stress_test.md) | 压测复测指南：环境、样例、场景与结果比较 |
| [docs/release-v0.3.3.md](docs/release-v0.3.3.md) | 当前版本说明 |

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
