# 可选：预拉取 dub 依赖（见 dub.json）。
# 用法: .\scripts\setup-windows.ps1

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Push-Location $ProjectRoot
try {
    Write-Host "Fetching dub dependencies..."
    dub fetch
    Write-Host "Done." -ForegroundColor Green
} finally {
    Pop-Location
}
