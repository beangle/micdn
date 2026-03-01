---
description: D 语言编码与格式风格（beangle-micdn）
globs: **/*.{d,di}
alwaysApply: true
---

# D 语言编码风格

## 许可证头（强制）

- 所有 `.d` / `.di` 源码文件必须在**首行之前**添加 GPLv3 许可证块注释。
- 格式如下（保留空行与星号对齐）：

  ```
  /* Copyright (C) 2023 Beangle
   *
   * This program is free software: you can redistribute it and/or modify
   * it under the terms of the GNU General Public License as published by
   * the Free Software Foundation, either version 3 of the License, or
   * (at your option) any later version.
   *
   * This program is distributed in the hope that it will be useful,
   * but WITHOUT ANY WARRANTY; without even the implied warranty of
   * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   * GNU General Public License for more details.
   *
   * You should have received a copy of the GNU General Public License
   * along with this program.  If not, see <https://www.gnu.org/licenses/>.
   */
  ```

- 许可证块与 `module` 声明之间保留一个空行。

## 格式与括号

- 使用 **dfmt + .editorconfig**，保持：
  - 缩进：**2 个空格**，不使用 Tab
  - 最大行宽：**120 列**
  - 括号风格：**OTBS**（One True Brace Style）
    - `if (cond) { ... } else { ... }`
    - `class Foo { ... }` / `struct Bar { ... }`
- 字符串连接使用 `~` 而不是 `+`。

## 模块与导入

- 顶部先写 `module`，然后是标准库 import，再是第三方/本项目 import。
- 对同一模块的选择性导入合并到一行，例如：
  `import std.file : getcwd, exists;`
- 避免未使用的 import。

## 命名与常量

- 类型名：`PascalCase`（`Config`, `ContextGroup`）。
- 函数/变量：`camelCase`（`firstSegment`, `readConfig`）。
- 使用 `immutable` 或 `const` 表达只读意图（如 `immutable Repo repo`）。

## 注释风格

- **公开 API（函数、类、重要成员）** 使用 Ddoc 块注释 `/** ... */`，便于 `dub build -b ddox` 生成文档。
- **多行注释** 统一用 `/** ... */` 块注释，不要使用 `///` 或嵌套 `/** */`；**第二行及之后每行开头用四个空格**做排版缩进（不用 Tab）。
- **格式约定**：
  - 第一行：一句话摘要，说明“做什么/返回什么”，句末加句号。
  - 空一行后（可选）：补充说明、边界条件等；从第二行起行首统一 **4 个空格** 缩进。
  - 若有参数/返回值，使用 `Params:`、`Returns:` 等 Ddoc 小节，小节内说明行同样 4 空格开头。
- **示例**：

  ```d
  /** Returns the decoded version of a form encoded string.

      Form encoding is the same as normal URL encoding, except that
      spaces are replaced by plus characters.
  */
  string decodeForm(string s) { ... }
  ```

  带参数与返回值时（块内续行仍 4 空格）：

  ```d
  /** 检查给定逻辑路径对应的资源类型。

      Returns:
         0 = 不存在或路径非法
         1 = 目录
         2 = 普通文件
  */
  int check(string path) const { ... }
  ```

- 单行 Ddoc 可用 `///`；多行用 `/** ... */` 且第二行起 4 空格。仅实现细节用 `//`。

## 结构与逻辑

- 条件与循环：
  - 优先使用早返回，减少嵌套层级。
  - 简单分支可以用一行 `if (cond) return;`。
- 字符串路径处理时统一用 `std.path`（如 `buildPath`、`dirName`），避免手工拼接 `/`。
- 对 URL/path 相关逻辑（如 `firstSegment`）保持注释解释输入/输出约定。

## 单元测试（含 silly 集成）

- 所有 `unittest` 块加上 **字符串 UDA 名称**，便于 silly 过滤：
  - `@("asset toXml multiple contexts") unittest { ... }`
- 测试应：
  - 独立可运行，不依赖外部状态（除非明确是集成测试）。
  - 只在必要时输出日志；默认不 `writeln` 调试信息。
- 主程序入口使用：
  ```d
  version (unittest) {
  } else {
    void main(string[] args) { ... }
  }
  ```
  确保 `dub test` 时由测试运行器接管，不自定义 `main()`。

## 配置与工具

- 代码格式化一律通过 dfmt（结合 `.editorconfig`）：
  - 在编辑器中使用 `format-d-current-file` / `format-d-all` 任务。
- 不手动修改 dfmt 已经规范好的格式，除非逻辑或可读性确有需要。

