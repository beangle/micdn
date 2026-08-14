# Micdn v0.3.2 Release Notes

**发布日期：** 2026-08-14
**对比基线：** [v0.3.1](https://github.com/beangle/micdn/compare/v0.3.1...v0.3.2)

---

## 概要

v0.3.2 的主题是「内置解压、更干净的镜像、可移植的静态二进制」。

- **tgz 解压内置**：npm 包部署不再依赖宿主 `tar` 命令，改为纯 D 实现（`src/micdn/fs/tar.d`）——`std.zlib` 流式解 gzip + 自实现 tar 解析，支持 ustar、GNU longname（`L`）、pax（`x`）扩展头、prefix 拼接、symlink/hardlink 与 mode 保留。运行时外部命令依赖收敛为**仅 `curl` 一个**（远端下载）。
- **下载双后端**：新增 `src/micdn/web/curl.d`——默认构建调用宿主 `curl` 命令；`executable-static` 配置静态链接 libcurl，下载不再依赖宿主 curl/openssl。
- **scratch 静态镜像**：`Dockerfile.scratch` + `scripts/build_scratch.sh` 产出 LDC musl **全静态**二进制（自编最小静态 libcurl + CA 证书），无 shell / apk / 调试工具，**无任何动态依赖**（连 musl loader 都不带），可拷到任意 x86_64 Linux 直接运行；镜像约 21.2MB。
- **容器可用性修复**：容器默认配置改监听 `0.0.0.0:8888`（admin 端点仍 localhost-only），并创建、`chown` `/var/log/micdn`，默认配置开箱即可写日志。
- **xi:include 修复**：展开前先剥离 XML 注释，注释里的示例 include（如 `<!-- <xi:include href="blob.xml" /> -->`）不再被误当真实指令导致配置加载失败。

无 Breaking Change，`micdn.xml` 配置无需调整。

---

## 版本评价

### 内置 tgz 解压

- 原实现把解压委托给宿主 `tar` 命令，对精简系统（scratch 镜像、CentOS 7 最小安装等）不友好。现在 `extractTgz(tgzFile, baseDir)` 在进程内完成全部工作：
  - gzip 层：`std.zlib.UnCompress` 流式解压，先校验魔数（`1f 8b`），解压总量限制 ≤2GiB；
  - tar 层：支持 ustar 与 GNU/pax 变体——`L`（GNU longname）、`x`（pax path/linkpath/size 覆盖）、prefix 拼接、硬链接/符号链接、mode 保留；
  - 安全防护与 zip 侧同口径：条目数 ≤2 万、拒绝绝对路径与 `..` 穿越、超深/超长条目拒绝、写盘前校验父链无包内创建的符号链接（防写穿 `baseDir`）。
- 效果：README「运行时系统命令依赖」从「curl + tar」收敛为**仅 `curl`**；AUR / deb / rpm 的 `Depends` 相应不再需要 tar（打包侧见 `docs/build_aur.md` / `docs/build_linux.md`）。
- 实现独立成模块：`file.d` 只保留 zip/manifest/部署逻辑，tar 解析集中在 `src/micdn/fs/tar.d`，配套单测迁至 `test/micdn/fs/tar_test.d`。

### scratch 静态镜像

- `scripts/build_scratch.sh`（挂载约定与 `build_image.sh` 相同：`~/.dub` → `/root/.dub`、`~/.cache/alpine-apk` → `/var/cache/apk`）构建 `micdn:<version>-scratch` 镜像。
- builder 阶段**自编最小静态 libcurl**：Alpine 预编译的 `libcurl.a` 含 brotli/psl 等引用，`ld.lld` 链接报 undefined symbol，因此改为 `autoreconf -fi && ./configure`（`--disable-shared --enable-static --with-openssl`，剔除 brotli/zstd/nghttp2/idn2/psl/ares/ldap/rtsp/dict/telnet/tftp/pop3/imap/smtp/gssapi 等）后 `make -C lib`；curl 源码需自备 `.curl-src/`（git 树，构建时生成 configure，不随仓库分发，见 [build_static_portable.md](./build_static_portable.md)）。
- 链接使用 `DFLAGS="-link-defaultlib-shared=false -L-static"` + `dub build --config=executable-static` 全静态（druntime/phobos/musl/libcurl/openssl/zlib 全部静态）；scratch 根目录只组装 CA 证书、容器默认配置与 passwd/group，**连 musl loader 都不需要**。
- **可移植性**：`readelf -d` 无 NEEDED、`ldd` 输出 `statically linked`；镜像内未放 musl loader 仍正常运行、HTTPS 下载实测成功——产物可拷到任意 x86_64 Linux 直接运行（包括无 curl、无高版本 openssl 的老系统）。镜像约 21.2MB（`/micdn` 约 20.97MB 全静态 + CA 证书）。
- 入口直接 `/micdn -f /etc/micdn/micdn.xml`（无 shell、无 entrypoint 脚本），`USER 100:101` 运行。

### 下载双后端（curl.d）

- 新增 `src/micdn/web/curl.d`，`curlDownload(url, local)` 签名不变，通过编译开关切换：
  - 默认 `dub build`：调用宿主 `curl` 命令，行为与 v0.3.1 一致；
  - `dub build -c executable-static`：`version(MicdnUseLibcurl)` 走 `etc.c.curl` 绑定**静态链接 libcurl**（非 `std.net.curl` 的 dlopen 动态加载），不依赖宿主 curl/openssl。
- TLS 配置 `vibe-stream:tls` 从 `openssl-static` 回退为 `notls`：micdn 本身是 HTTP CDN 服务，TLS 由反向代理承担；全局静态 OpenSSL 会把二进制增大约 6MB，且 dub 包 `openssl-static` 的预编译 `.a` 针对较新 glibc 构建，CentOS 7 等老系统有兼容风险（configuration 内 `subConfigurations` 还触发过 dub 1.41 配置被忽略的问题）。静态库改为在 `dub.json` 的 `executable-static` 中**显式写库路径**。

### 容器可用性

- `scripts/container/micdn.xml` 监听从 `127.0.0.1:8888` 改为 `0.0.0.0:8888`，`podman run -p` 发布端口直接可用；`/admin/*` 仍仅接受 localhost 来源。
- `Dockerfile` / `entrypoint.sh` 创建并 `chown -R micdn:beangle /var/log/micdn`，默认 `log-file="/var/log/micdn/micdn.log"` 不再因目录缺失/属主问题启动失败。

### xi:include

- `expandXiIncludes` 展开前先 `stripXmlComments`（支持跨行 `<!-- ... -->`），注释掉的 include 示例不再触发解析；未闭合注释原样保留，交给后续 DOM 解析报错。新增回归单测（`test/micdn/xml/xinclude_test.d`）。

---

## 升级注意

- **无 Breaking**：配置、CLI、HTTP 接口均兼容 v0.3.1。
- 宿主不再需要 `tar` 命令；已安装旧版本的系统在升级后可直接移除对 tar 的依赖声明。
- 静态构建（`-c executable-static` / scratch 镜像）产物**不依赖宿主 curl**；默认构建与 AUR / deb / rpm 仍声明 `Depends: curl`。
- 容器镜像标签：Alpine 版 `micdn:0.3.2`，scratch 版 `micdn:0.3.2-scratch`（均由构建脚本从 `dub.json` 读取，不接受命令行改 tag）。

---

## 提交统计

v0.3.2 相对 v0.3.1 共 3 个提交（另含未提交的镜像优化）：

- `cd0b1ba` Release v0.3.2: built-in tgz extraction and scratch image（tgz 解压内置 `src/micdn/fs/tar.d`、scratch 镜像初版、容器启动修复与 xi:include 注释处理、版本号提升至 0.3.2）
- `91b707a` Use openssl-static for TLS to avoid runtime OpenSSL dependency（后因静态库兼容性风险回退为 `notls`）
- `c516222` Add curl.d download backends: system curl or static libcurl（`src/micdn/web/curl.d` 双后端 + `executable-static` 配置）
- 未提交：`Dockerfile.scratch` 自编最小静态 libcurl 优化（镜像 25.4MB → 21.2MB，移除 curl 动态依赖与 musl loader）

---

## 测试

`dub test --compiler=ldc2`：**149 passed, 0 failed**。

新增/更新的覆盖：

- fs：tar 解压独立单测（基础文件/目录与 mode 保留、symlink/hardlink、GNU longname + pax path 覆盖、穿越与非 gzip 拒绝，`test/micdn/fs/tar_test.d`）
- xml：`xi:include` 位于 XML 注释内时被忽略、真实 include 正常展开（`test/micdn/xml/xinclude_test.d`）
