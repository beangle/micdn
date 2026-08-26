# Micdn v0.3.3 Release Notes

**发布日期：** 2026-08-26  
**对比基线：** [v0.3.2](https://github.com/beangle/micdn/compare/v0.3.2...v0.3.3)

---

## 概要

v0.3.3 是维护性小版本，主题是「开箱即用修正」：默认配置与默认行为更符合直觉，热加载可重复触发。

- **热加载修复**：SIGHUP 热加载只生效一次——eventcore 事件回调为一次性消费（触发后即移除），改为在回调内重新挂载事件，`systemctl reload` 可持续触发。
- **默认路径修复**：默认 maven/npm 仓库 base（`~/maven` / `~/npm`）改用 `expandTilde` 展开，配置未显式给 `base` 时不再在工作目录创建字面 `~` 目录。
- **SPA 默认值**：www doc 未配置 `try-file` 时默认 `index.html`，SPA 深链接回退开箱即用，无需再逐 doc 显式声明。

无 Breaking Change，`micdn.xml` 配置无需调整。

---

## 版本评价

### 热加载可持续触发

- eventcore 的 `wait` 事件回调为一次性消费：SIGHUP 触发一次后回调即被移除，后续信号不再有任何效果，`systemctl reload` 第二次起静默失败。
- `startSighupReloadThread` 改为在回调内先重新挂载事件再派发 reload 任务（`eventDriver.events.wait(reloadEvent, &onReloadEvent)`），每次触发后自动续期。
- 已本地连发两次 SIGHUP 冒烟验证：两次均输出 `Config reload (SIGHUP): ok`，行为与 `systemctl reload` 的实际语义一致。

### 默认仓库路径不再产生字面 `~` 目录

- `MavenRepoConfig.defaultConfig()` / `NpmRepoConfig.defaultConfig()` 的 base 由 `"~/maven"` / `"~/npm"` 改为 `expandTilde("~/maven")` / `expandTilde("~/npm")`。
- 此前 `<maven/>` / `<npm/>` 未显式配置 `base` 时，默认路径按相对路径处理，会在进程工作目录下创建字面 `~` 目录（如 `/etc/micdn/~/maven`），下载缓存落点与文档描述（用户主目录）不符。
- 展开发生在配置构造期，显式配置 `base="${micdn.home}/..."` 等路径的行为不受影响；新增单测覆盖两个默认值。

### www doc 默认 try-file

- `parseWww` 读取 `try-file` 属性时默认值由空串改为 `index.html`：未配置的 SPA/文档站 doc 自动获得深链接回退（`$uri` 未命中 → 所属 doc 的 `try-file`），与 README 配置示例的推荐写法一致。
- 显式配置 `try-file`（含其他文件名）行为不变；校验规则不变（必须为不带路径分隔符的单个文件名）。
- 新增单测：未配置 `try-file` 的 www doc 解析结果为 `index.html`；`resolve` 的 try-file 缺失警告与运行期回退逻辑不受影响。

---

## 升级注意

- **无 Breaking**：配置、CLI、HTTP 接口均兼容 v0.3.2。
- 行为变化一：此前未显式配置 `try-file` 的 www doc 无深链接回退，升级后默认回退 `index.html`——这正是 README 长期推荐的做法；若个别 doc 不希望回退，可显式写 `try-file=""` 禁用（属性缺省才套用 `index.html` 默认值，显式空串保留为空）。
- 行为变化二：`<maven/>` / `<npm/>` 未显式配置 `base` 时，默认缓存目录从「工作目录下的字面 `~/maven`」变为「用户主目录下的 `~/maven`」；生产环境均建议显式配置 `base`，不受影响。
- 容器镜像标签：Alpine 版 `micdn:0.3.3`，scratch 版 `micdn:0.3.3-scratch`（均由构建脚本从 `dub.json` 读取，不接受命令行改 tag）。

---

## 提交统计

v0.3.3 相对 v0.3.2 共 1 个提交 + 本次发布提交：

- `9df6f26` Fix repo base defaults and www try-file default（`expandTilde` 展开默认 maven/npm base、www doc 默认 `try-file=index.html`、SIGHUP 事件回调重新挂载；含 2 个新增单测）
- 本次发布提交：版本号提升至 0.3.3（`dub.json` / `src/micdn/main.d` / README）、changelog 与本文档定稿

---

## 测试

`dub test --compiler=ldc2`：**151 passed, 0 failed**（较 v0.3.2 的 149 增加 2 个）。

新增/更新的覆盖（`test/micdn/config_test.d`）：

- 默认 maven/npm 仓库 base 展开 `~`：`MavenRepoConfig.defaultConfig().base == expandTilde("~/maven")`、`NpmRepoConfig` 同理
- www doc 未配置 `try-file` 时默认 `index.html`
