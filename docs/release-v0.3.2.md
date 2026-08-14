# Micdn v0.3.2 Release Notes

**发布日期：** 2026-08-14
**对比基线：** [v0.3.1](https://github.com/beangle/micdn/compare/v0.3.1...v0.3.2)

---

## 概要

v0.3.2 的主题是「内置解压、更干净的镜像」。

- **tgz 解压内置**：npm 包部署不再依赖宿主 `tar` 命令，改为纯 D 实现（`src/micdn/fs/tar.d`）——`std.zlib` 流式解 gzip + 自实现 tar 解析，支持 ustar、GNU longname（`L`）、pax（`x`）扩展头、prefix 拼接、symlink/hardlink 与 mode 保留。运行时外部命令依赖收敛为**仅 `curl` 一个**（远端下载）。
- **scratch 静态镜像**：新增 `Dockerfile.scratch` + `scripts/build_scratch.sh`，产出 LDC musl 全静态、无 shell / 无 apk / 无调试工具的镜像（约等于"一个二进制 + CA 证书 + curl"），镜像内仅携带 curl 及其动态依赖。
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
- builder 阶段 `DFLAGS="-link-defaultlib-shared=false -L-static"` 全静态链接（druntime/phobos/musl/zlib/gcc-unwind 全部静态）；scratch 根目录只组装 CA 证书、curl 及其动态依赖（musl 加载器放 `/lib`）、容器默认配置与 passwd/group。
- 入口直接 `/micdn -f /etc/micdn/micdn.xml`（无 shell、无 entrypoint 脚本），`USER 100:101` 运行。

### 容器可用性

- `scripts/container/micdn.xml` 监听从 `127.0.0.1:8888` 改为 `0.0.0.0:8888`，`podman run -p` 发布端口直接可用；`/admin/*` 仍仅接受 localhost 来源。
- `Dockerfile` / `entrypoint.sh` 创建并 `chown -R micdn:beangle /var/log/micdn`，默认 `log-file="/var/log/micdn/micdn.log"` 不再因目录缺失/属主问题启动失败。

### xi:include

- `expandXiIncludes` 展开前先 `stripXmlComments`（支持跨行 `<!-- ... -->`），注释掉的 include 示例不再触发解析；未闭合注释原样保留，交给后续 DOM 解析报错。新增回归单测（`test/micdn/xml/xinclude_test.d`）。

---

## 升级注意

- **无 Breaking**：配置、CLI、HTTP 接口均兼容 v0.3.1。
- 宿主不再需要 `tar` 命令；已安装旧版本的系统在升级后可直接移除对 tar 的依赖声明。
- 容器镜像标签：Alpine 版 `micdn:0.3.2`，scratch 版 `micdn:0.3.2-scratch`（均由构建脚本从 `dub.json` 读取，不接受命令行改 tag）。

---

## 提交统计

v0.3.2 相对 v0.3.1 共 1 个提交 + 本次发布改动：

- `75cb7e6` 容器启动修复与 xi:include 注释处理（`/var/log/micdn` 创建/chown、容器监听 `0.0.0.0`、剥离 XML 注释、回归测试）
- 本次发布：tgz 解压内置（`src/micdn/fs/tar.d`，移除宿主 tar 依赖）、scratch 镜像（`Dockerfile.scratch` / `build_scratch.sh`）、文档更新、版本号提升至 0.3.2、changelog 与本文档定稿

---

## 测试

`dub test --compiler=ldc2`：**149 passed, 0 failed**。

新增/更新的覆盖：

- fs：tar 解压独立单测（基础文件/目录与 mode 保留、symlink/hardlink、GNU longname + pax path 覆盖、穿越与非 gzip 拒绝，`test/micdn/fs/tar_test.d`）
- xml：`xi:include` 位于 XML 注释内时被忽略、真实 include 正常展开（`test/micdn/xml/xinclude_test.d`）
