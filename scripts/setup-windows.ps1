# Windows 构建前置脚本：获取并打补丁的 vibe-d-postgresql
# 运行: .\scripts\setup-windows.ps1
# 完成后执行 dub build -c executable-windows

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# 1. 获取 vibe-d-postgresql 3.2.1
Write-Host "Fetching vibe-d-postgresql 3.2.1..."
Push-Location $ProjectRoot
dub fetch vibe-d-postgresql --version=3.2.1
Pop-Location

# 2. 定位 dub 缓存
$dubCache = $env:LOCALAPPDATA + "\dub\packages\vibe-d-postgresql\3.2.1\vibe-d-postgresql"
if (-not (Test-Path $dubCache)) {
    Write-Error "vibe-d-postgresql 3.2.1 not found at $dubCache"
}

# 3. 复制到 packages/
$packagesDir = Join-Path $ProjectRoot "packages"
$targetDir = Join-Path $packagesDir "vibe-d-postgresql"
New-Item -ItemType Directory -Force -Path $packagesDir | Out-Null
if (Test-Path $targetDir) { Remove-Item -Recurse -Force $targetDir }
Copy-Item -Recurse $dubCache $targetDir

# 4. 应用 createFileDescriptorEvent 的 Windows 兼容补丁
$pkgFile = Join-Path $targetDir "source\vibe\db\postgresql\package.d"
$content = Get-Content $pkgFile -Raw
$old = @"
        // vibe-core right now supports only read trigger event
        // it also closes the socket on scope exit, thus a socket duplication here
        return createFileDescriptorEvent(this.posixSocketDuplicate, FileDescriptorEvent.Trigger.read);
"@
$new = @"
        // vibe-core right now supports only read trigger event
        // it also closes the socket on scope exit, thus a socket duplication here
        version (Windows) {
            // On Windows, socket handles are ulong; vibe-core expects int for now.
            return createFileDescriptorEvent(cast(int) this.posixSocketDuplicate, FileDescriptorEvent.Trigger.read);
        } else {
            return createFileDescriptorEvent(this.posixSocketDuplicate, FileDescriptorEvent.Trigger.read);
        }
"@
if ($content -notmatch [regex]::Escape($old.Trim())) {
    Write-Error "Patch pattern not found - file may have changed"
}
$content = $content.Replace($old, $new)
[System.IO.File]::WriteAllText($pkgFile, $content, [System.Text.UTF8Encoding]::new($false))

# 5. 创建 lib 目录并复制 pq.lib
$libraryDir = Join-Path $ProjectRoot "lib"
New-Item -ItemType Directory -Force -Path $libraryDir | Out-Null
$pgLib = "D:\Program Files\PostgreSQL\17\lib\libpq.lib"
if (Test-Path $pgLib) {
    Copy-Item $pgLib (Join-Path $libraryDir "pq.lib")
    Write-Host "Copied libpq.lib -> lib/pq.lib"
} else {
    Write-Host "请手动执行: Copy-Item `"<PostgreSQL路径>\lib\libpq.lib`" -Destination `"lib\pq.lib`"" -ForegroundColor Yellow
}

Write-Host "Setup done. Run: dub build -c executable-windows" -ForegroundColor Green
