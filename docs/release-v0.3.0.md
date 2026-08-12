# Micdn v0.3.0 Release Notes

**发布日期：** 2026-08-13  
**对比基线：** [v0.2.6](https://github.com/beangle/micdn/compare/v0.2.6...v0.3.0)

---

## 概要

v0.3.0 在 v0.2.6 基础上：新增 **gzip 预压缩 sidecar**（请求触发 + 后台线程压缩），www 的 doc 匹配重构为 **`WwwDocTree` 前缀树**（更快、更严），并按 doc 提供 **`auto-gzip` 开关**。同时移除了 www 的 `<dir>` 挂载，收紧了服务范围（未挂 doc 的物理文件不再对外提供），并统一了仓库 base 的绝对路径语义。

**`micdn.xml` 存在 Breaking Change**（见下方升级注意）：www `<dir>` 不再支持；重复 doc name 报错；`www.base` 下未挂 `<doc>` 的文件不再被服务。

共 **8 个提交**，**27 个文件**变更（+1173 / −218 行）。

---

## 亮点总结

| 类别 | 改进 |
|------|------|
| **性能** | gzip 预压缩：请求线程只读 `path.gz`，后台单 worker 生成 sidecar，写 `tmp` 后原子 `rename` |
| **WWW** | doc 匹配改为 `WwwDocTree` 前缀树，O(路径段数) 查找，断链回退最长 doc 前缀 |
| **WWW** | `<doc auto-gzip="false">` 按 doc 关闭 gzip（不发送已有 `.gz` 也不生成） |
| **安全** | `www.base` 下未挂 `<doc>` 的物理文件不再服务（404，且不读盘）；重复 doc name 配置报错 |
| **内部** | 仓库 base 统一绝对路径语义（构造时校验 + 归一）；gzip 模块并入 `micdn.web` |

---

## 新功能

### gzip 预压缩 sidecar

static / www 部署的文本类静态资源（`js`、`css`、`html`、`svg`、`json`、`xml`、`txt`、`map` 等）采用「请求触发 + 后台线程压缩」模式：

- 请求线程只读：客户端 `Accept-Encoding` 接受 gzip 且存在 `path.gz` 时直接发送预压缩内容（`Content-Encoding: gzip`、`Vary: Accept-Encoding`）；否则按源文件服务，并把缺失 sidecar 的文件路径放入后台压缩队列。
- `Accept-Encoding` 判定为简化实现：面向现代浏览器，仅按子串识别 `gzip`（大小写不敏感），不处理 `q=0` 拒绝与 `*` 通配等完备语义。
- 压缩由独立后台 worker 完成（单消费者，去重队列上限 8192，惰性启动），写 `tmp` 后原子 `rename`，无文件写竞争。
- 仅当压缩后确实更小才落盘；小于 1KB 或超过 8MB 的文件不压缩（保护性区间，避免无收益入队与大内存分配）。
- 已压缩格式（图片、字体、`.gz`/`.br` 等）不生成 sidecar；`Range` 请求与逗号合并（`/a/b,c.js`）不返回 gzip。
- asset 的 `<dir>` dyna bundle 完全忽略 gzip（不发送也不生成）。

详见 README「gzip 预压缩」。

### www doc 前缀树匹配与 per-doc `auto-gzip`

```xml
<www base="/var/lib/micdn/www">
  <doc name="manual" zip="/srv/releases/manual.zip" />
  <doc name="spa" zip="/srv/releases/spa.zip" try-file="index.html" auto-gzip="false" />
</www>
```

- doc 挂靠到 `WwwDocTree`（每节点一个单词段，每节点至多一个 doc）；请求按 URI 段逐级匹配，断链时回退到最后一个挂 doc 的节点。
- 未匹配到任何 doc 的请求**不访问文件系统**直接 404；`www.base` 下未挂 doc 的物理文件不再服务。
- `auto-gzip="false"` 时该 doc 完全忽略 gzip（不发送已有 `.gz` 也不生成），默认参与。
- `WwwRepo.get` 返回 `WwwFile { path, doc }`：doc 匹配但文件缺失时 `path` 为 null 且保留 `doc`，为 doc 粒度兜底（如自定义 404）预留。

---

## 行为变更

### www 移除 `<dir>` 挂载（Breaking）

`<doc … dir="…">` 不再支持，解析期直接报错；请改用 `npm` 或 `zip`。

### 服务范围收紧（Breaking）

`www.base` 下未挂载为 `<doc>` 的物理文件（含历史遗留内容）不再对外服务，请求返回 404。

### 重复 doc name 报错（Breaking）

同名（归一化后）doc 在 XML 解析期与树构造期都会报错，不再静默覆盖。

### 其它

- 仓库 base（maven / npm / asset / www）统一为绝对路径语义：`config.*.base` 解析即归一，repo 构造时校验非空。
- gzip 模块由 `micdn.gzip` 移入 `micdn.web.gzip`（纯内部重构，无配置影响）。

---

## 升级注意

1. www 配置若使用 `dir`，需先改为 `npm` 或 `zip` 再升级。
2. 检查 `www.base` 下是否有未挂 doc 的历史文件——升级后这些路径将 404。
3. 检查配置中是否有重复 doc name（此前会静默后者覆盖前者）。
4. 非必需：无需为 gzip 预压缩做任何配置；需要按 doc 关闭时使用 `auto-gzip="false"`。

---

## 测试

`dub test --compiler=ldc2`：**115 passed, 0 failed**。

新增/更新的覆盖：

- gzip：eligibility（白名单、大小区间、符号链接）、sidecar 发送与回退、队列准入与去重、worker 停止/重启
- www：`WwwDocTree` 最长前缀 / 断链回退 / 空树 / 重复 endpoint；doc-only 服务（未挂 doc 文件 404）；try-file 与静态资源回退
- config：`auto-gzip` 默认值、解析与 `parse → toXml → parse` round-trip；重复 doc name 拒绝
- base：仓库构造非空校验与绝对路径归一
