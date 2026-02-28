# Windows 构建说明

Linux 使用 dub  registry 的 vibe-d-postgresql，无需额外文件。Windows 需先运行前置脚本，然后使用独立配置构建。

## 已处理问题

1. **createFileDescriptorEvent(ulong) 类型不匹配**  
   vibe-core 只接受 `int`，而 Windows 下 socket 为 `ulong`。  
   由 `scripts/setup-windows.ps1` 自动对 vibe-d-postgresql 打补丁。

2. **dpq2 std.conv 缺失**  
   vibe-d-postgresql 固定到 `3.2.1`（dpq2 1.2.4），避免 1.3.0-alpha 的 Windows 编译错误。

## 构建步骤

**首次在 Windows 上构建时**：

```powershell
.\scripts\setup-windows.ps1
dub build -c executable-windows
```

脚本会：获取 vibe-d-postgresql、打补丁到 `packages/`、复制 `libpq.lib` 为 `lib/pq.lib`（PostgreSQL 默认路径 `D:\Program Files\PostgreSQL\17`，其他路径需自行修改脚本）。

**运行**：将 PostgreSQL 的 `bin` 目录加入 PATH，或将 `libpq.dll` 放到可执行文件同目录。
