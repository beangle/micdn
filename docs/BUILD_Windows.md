# Windows 构建说明

Blob 元数据在 **Linux** 上通过文件 **`user.*` 扩展属性** 存储（`user.owner`、`user.sha1` 等）；**非 Linux** 目标上为占位实现，不写入扩展属性，仅适合本地编译或联调。

## 依赖

- **LDC** 或 DMD（满足 `dub.json` 中 `toolchainRequirements`）。
- 无需 SQLite；已移除 `d2sqlite3` 依赖。

## 构建步骤

```powershell
dub build
```

（若项目日后增加 `executable-windows` 等配置，以 `dub.json` 为准。）

可选：预先拉取依赖以便离线构建：

```powershell
dub fetch
```
