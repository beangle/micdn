# micdn

轻量 CDN / 静态资源服务：Maven、npm、WebJar/本地静态包、WWW 文档站点与 Blob 存储（含可选 S3 兼容 API）。配置驱动，单进程 HTTP。

**License:** GPLv3 · **Version:** 0.3.3

## 功能

| 服务 | 说明 |
|------|------|
| **static** | 从 Maven GAV（WebJar）、npm 包或本地目录部署前端资源，按 bundle 提供 |
| **www** | SPA/文档站：npm / zip；支持 `try-file`；zip 可 `auto-deploy`（Linux inotify） |
| **maven** / **npm** | 本地缓存 + 上游 remote 拉取 |
| **snapshot** | 只读本地快照仓库（`/snapshot`），服务 `install` 装入的 maven SNAPSHOT，不访问上游 |
| **blob** | 对象存储；可选 S3 兼容接口 |
| **admin** | localhost 只读指标 `/admin/metrics`、配置查看与 reload |

路径属性支持 `${micdn.home}` 与 `~` 展开。

## HTTP 端点

| 前缀 | 说明 |
|------|------|
| `/maven` | 正式版：本地缓存 + 上游 remote 拉取；命中 SNAPSHOT 路径一律 404 |
| `/snapshot` | 本地 SNAPSHOT（只读）：`micdn install` 装入后由它提供，别名请求 302 到最新时间戳文件 |
| `/npm` | npm registry：packument（交付时替换 `{origin}` 占位符）与 tgz |
| `/static` | 静态资源（配置了 `<static>` 时） |
| `/blob`、`/s3` | 对象存储与 S3 兼容接口（配置了 `<blob>` 时） |
| `/admin` | 本机只读指标 `/admin/metrics`、配置查看与 reload |
| `/*` | www 兜底（配置了 `<www>` 时，按各 `<doc>` 名匹配） |

## 快速开始

```bash
# 依赖：ldc、dub（见 docs/build_linux.md）
dub build --build=release-nobounds --compiler=ldc2

./target/micdn -f resources/micdn.xml          # 启动 HTTP
./target/micdn -f /etc/micdn/micdn.xml resolve # 解析并部署全部 www/static（不启动 HTTP）
./target/micdn -f /etc/micdn/micdn.xml deploy www manual
./target/micdn -f /etc/micdn/micdn.xml deploy static bootstrap --force
./target/micdn -f /etc/micdn/micdn.xml clean --yes # 清除 www/static 部署目录（交互终端下会逐项确认；maven/npm 缓存与 blob 数据不清理）
./target/micdn -f /etc/micdn/micdn.xml install build/xxx-0.0.2.tgz # 本地 npm 包入库并生成 packument
./target/micdn -f /etc/micdn/micdn.xml install target/x-1.0.0-20250803.132600-31.jar # 本地 maven SNAPSHOT 入库
```

`-f` 可为本地文件、目录（使用 `DIR/micdn.xml`）或 URL（下载到 `~/micdn.xml`）。

## 本地发布 npm 包

开发版/内网包不必发到公网 registry：把 `npm pack` 产出的 tgz 交给 **`micdn install`**，它按 npm 目录规范
装入配置里的 `<npm base>`（`{scope|_}/{name}/{version}/`），并在 `{npm base}/{包名}` 写出 packument 元数据：

```bash
npm pack                                                        # 产出 xxx-0.0.3-dev.1.tgz
micdn -f /etc/micdn/micdn.xml install xxx-0.0.3-dev.1.tgz --tag dev

# 消费方（registry 指向 micdn 的 /npm，见 docs/reverse_proxy.md）
npm install @scope/xxx@dev --registry http://micdn:8888/npm/
```

元数据全部由目录内容推导：`dist.integrity` / `dist.shasum` 由 tgz 字节算出，`dist-tags.latest` 取最高**正式**版
（预发布不会顶替 latest），预发布版本按 `dev` / `next` / `beta` / `rc` / `alpha` / `canary` 自动打通道 tag，
`--tag` 可再挂一个自定义 tag。删掉 `{npm base}/{包名}` 后再 `install` 一次即可重建元数据。

`dist.tarball` 不写死主机，而是写成占位符 `{origin}/npm/@scope/xxx/-/xxx-0.0.3-dev.1.tgz`，由 npm 服务在**交付时**
替换成访问方看到的 origin，按请求推导（`Host` 与反代的 `X-Forwarded-Proto` / `X-Forwarded-Host` / `X-Forwarded-Port`）。
因此同一个 packument 对 `http://micdn:8888`、`https://cdn.example.com` 都能给出可用地址，不需要在配置里写死对外地址。
从上游 registry 代理来的 packument（含 `https://registry.npmmirror.com/...` 绝对地址）不做替换，原样发送。

## 本地发布 maven SNAPSHOT

正式版走 `/maven`（本地缓存 + 上游 remote 拉取）；开发版 SNAPSHOT 不走上游，落在独立的本地仓库、由 **`/snapshot`**
只读提供。仓库位置由 `<maven>` 的 `<snapshot base="..."/>` 配置（默认 `${micdn.home}/snapshots`）；**即使不写
`<snapshot>` 元素也会建库并挂载 `/snapshot`**。

把 `mvn deploy` 产出的带时间戳构件交给 **`micdn install`**：

```bash
micdn -f /etc/micdn/micdn.xml install target/beangle-commons-5.0.0-20250803.132600-31.jar
```

坐标（groupId / artifactId / version）取自工件内部：`META-INF/maven/{group}/{artifact}/pom.properties`（war 在
`WEB-INF/classes/` 下），没有则退回 `MANIFEST.MF` 的 `Implementation-Vendor-Id` / `-Title` / `-Version`；`.pom`
直接解析 XML。install 会复制构件、写 `.sha1`，并扫描版本目录重写 `maven-metadata.xml`（`<snapshot>` 取最新时间戳，
`<snapshotVersions>` 列出最新构建的 jar/pom/classifier 等文件），元数据与构件一样由**写入方产出**，HTTP 侧只发文件。

消费方在 POM 里声明这个仓库即可：

```xml
<repositories>
  <repository>
    <id>micdn-snapshot</id>
    <url>http://micdn:8888/snapshot</url>
    <snapshots><enabled>true</enabled></snapshots>
    <releases><enabled>false</enabled></releases>
  </repository>
</repositories>
```

别名（不带时间戳）请求 `...-1.0.0-SNAPSHOT.jar` 会 `302` 到同目录最新的时间戳文件，`HEAD` 则以 `latest` 头返回实际
文件名；`.sha1` 请求同样支持。`/maven` 不再服务任何 SNAPSHOT（命中即 404），避免与 `/snapshot` 语义混淆。

## 配置示例

```xml
<micdn home="/var/lib/micdn" listen="127.0.0.1:8080">
  <maven base="${micdn.home}/maven">
    <remote url="https://repo1.maven.org/maven2/" />
    <snapshot base="${micdn.home}/snapshots" />
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
