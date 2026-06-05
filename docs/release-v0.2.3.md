# Micdn v0.2.3 Release Notes

**发布日期：** 2026-06-05  
**对比基线：** [v0.2.2](https://github.com/beangle/micdn/compare/v0.2.2...v0.2.3)

---

## 概要

v0.2.3 在 v0.2.2 基础上主要做了四块工作：**WWW/SPA 静态托管增强**、**离线 mount 子命令**、**全链路路径与安全加固**，以及 **systemd 启动与日志可观测性**改进。

共 **27 个提交**，**35 个文件**变更（+2205 / −659 行），测试覆盖显著扩充。

---

## 亮点总结

| 类别 | 改进 |
|------|------|
| **SPA 托管** | `try-file` 支持前端 History 路由；缺失 JS/CSS 等资源不再被 HTML 顶替 |
| **配置简化** | `<www><doc>` 改为 `name` + `npm`/`dir`/`zip` 属性，路径更直观 |
| **运维** | `mount www\|static` 离线部署；启动失败写 journal、退出码 2 防反复重启 |
| **安全** | Maven/NPM/Blob/S3/Zip 解压路径校验；S3 SigV4 与 zip bomb 防护 |
| **代码结构** | 合并 `micdn.web` 模块；新增 `micdn.web.ext` 统一扩展名判断 |

---

## 升级注意（Breaking Changes）

### 1. WWW `<doc>` 配置格式变更（必须改配置）

**旧版（v0.2.2）：**

```xml
<www>
  <doc location="/manual">
    <npm package="@xurp/manual@0.0.2" />
  </doc>
</www>
```

**新版（v0.2.3）：**

```xml
<www base="/var/cache/micdn/www">
  <doc name="manual" npm="@xurp/manual@0.0.2" try-file="index.html"/>
</www>
```

- `location="/manual"` → `name="manual"`（**不带前导 `/`**，支持 `a/b` 多级路径）
- 子元素 `<npm>` / `<dir>` / `<zip>` → 同名**属性**，三选一
- SPA 建议加 `try-file="index.html"`
- npm 包内目录用 `inner`（默认 `dist`）

### 2. endpoint 校验更严

HTTP 挂载前缀须以 `/` 开头且不以 `/` 结尾（不再允许空 endpoint）。

---

## 新功能

### WWW / SPA

- **`try-file` 属性**：`$uri` 与 `$uri/index.html` 未命中时，回退到 doc 根下指定文件（如 `index.html`），支持 `/m/edu/teaching/a/bc` 类深链接
- **静态资源 404 语义**：带 `.js`、`.css` 等扩展名且文件不存在时，**不再** try-file 成 HTML，避免浏览器 MIME 错误
- **mount 时校验**：部署阶段检查 `try-file` 是否存在，缺失打 `WARN`
- **www 兜底路由**：内置路由之后 `GET/HEAD /*` 匹配所有 doc
- **`index.html` 缓存**：HTML 使用 `no-cache`，其它静态资源 7 天

### CLI / 部署

```bash
micdn -f micdn.xml mount www              # 安装全部 doc
micdn -f micdn.xml mount www manual       # 安装指定 doc
micdn -f micdn.xml mount static           # 安装全部 static bundle
micdn -f micdn.xml mount static AdminLTE  # 安装指定 bundle
```

- **目录权限简化**：仅在 `www.base` / `static.base` 各做一次 `ensureDirWritable`（目录本身），不再递归 chmod；build 结束不再 `setReadOnly`

### 启动与 systemd

- 配置解析**前**不注册 logger，避免重复注册
- 启动阶段失败：`stderr` 输出 `micdn: …`（journal 可见），**退出码 2**
- `micdn.service`：`RestartPreventExitStatus=2`（坏配置不无限重启）；`StandardOutput/StandardError=journal`
- `listenHTTP` 成功后进程异常退出仍由 `Restart=on-failure` 拉起

### 模块

- **`micdn.web.ext`**：集中维护图片 / 静态资源扩展名；`isImage()`、`isStaticAsset()` 供 blob 与 www 复用（替代原 `BlobRepo.images`）

---

## 安全加固

- **路径穿越防护**：Maven/NPM 请求路径 URL 解码后再校验；Blob/S3 对象路径拒绝 `..` 及编码穿越
- **Zip/Jar 解压**：拒绝非法 entry 名、绝对路径、过长路径、过深目录；entry 数量与压缩比预检，降低 zip bomb 风险
- **S3 SigV4**：标准 signing key、signed-header 规范化、时间戳重放检查、PUT payload hash 绑定
- **S3 列表与下载**：分页；零字节 Range 处理；curl 超时与低速保护
- **Asset 模块**：路径解析与 `isPathUnder` 约束在仓库根内

---

## Bug 修复

- static bundle 刷新后 mount 路径错误
- www `index.html` 缓存策略不正确
- XML 解析错误信息更清晰
- 解压时错误配置可能导致的路径穿越

---

## 测试

新增 / 扩充测试：`www_test`、`config_test`、`fs/file_test`、`blob/s3_test`、`web/ext_test` 等，覆盖 try-file、mount、路径安全、S3 签名等场景。

---

## 详情（按模块）

### WWW（`src/micdn/www/`）

| 项目 | 说明 |
|------|------|
| 配置模型 | `WwwDocConfig.name` + 属性化 provider |
| 路由解析 | 最长前缀匹配多 doc（如 `a` 与 `a/b` 共存） |
| try-file 顺序 | `$uri` → 目录 `index.html` → try-file |
| 静态守卫 | `isStaticAsset(uri)` 为 true 且未命中 → 404 |
| mount | `mountDoc` 供 build 与 CLI 共用；symlink/npm/zip 三种来源 |

### 配置（`config.d` / `micdn.xsd`）

- 新增 `docNameType`、`try-file` XSD 定义
- 解析期校验 npm/dir/zip 恰填其一
- `try-file` 禁止 `..` 路径段

### Blob / S3

- 图片匿名下载改用 `isImage()`（含 `.avif`，扩展名大小写不敏感）
- 对象路径统一 `isSafeBlobObjectPath`
- S3 鉴权与列表行为加强

### 文件系统（`fs/file.d`）

- `ensureDirWritable`：仅 base 目录本身
- `extractTgzToDocBase` / zip 解压安全校验
- 保留递归 `setReadOnly`/`setWritable`（测试/手工用，有文档）

### Web 层重构

- `micdn.web.server` 合并进 `micdn.web` / `micdn.web.file`
- 共享 `getPath`、`decodeRepositoryUri`、`resolveRepositoryPath`

---

## 升级步骤

1. 按上文格式改写 `<www><doc>` 配置，SPA 加上 `try-file="index.html"`
2. 重新打包 / 安装 RPM，更新 `micdn.service`
3. 执行 `micdn -f /etc/micdn/micdn.xml mount www`（或按需 mount static）
4. `systemctl daemon-reload && systemctl restart micdn`
5. 配置错误时：`journalctl -u micdn -b -n 50` 查看 `micdn: …` 启动错误

---

## 完整提交列表

- `refactor(web)`: 统一扩展名集合并改进 SPA try-file 回退
- `detect try-file`: mount 阶段校验 try-file
- `fix(startup)`: 启动失败 stderr + 退出码 2
- 简化目录可写操作
- add try-file to xml
- `feat(www)`: try-file SPA 路由回退
- `refactor(www)`: doc 配置简化为 name + 属性
- support mount sub command
- refact www mount logic
- more test
- support `/*` as www backend endpoint
- better error xml report
- 增加安全路径检测函数
- 防止解压路径穿越
- more const
- simplify uri decoder under maven and npm
- enhance path protection in asset module
- merge package and server under module web
- add isPathUnder function
- enforce location start with `/`
- fix mount wrong path when bundle refreshed
- fix index.html cache setting in www
- Harden S3 list and file serving paths
- Harden S3 SigV4 authentication
- Harden zip extraction validation
- Harden repository and blob path validation
