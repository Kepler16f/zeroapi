# ZeroApi 全平台构建脚本
# 用法:
#   powershell -File tool\build.ps1                       # 交互式选择平台
#   powershell -File tool\build.ps1 -Platforms windows-arm64
#   powershell -File tool\build.ps1 -Platforms windows-arm64 -Installer
#   powershell -File tool\build.ps1 -Platforms all
# 说明: flutter build windows 不支持 --target-platform，Windows 产物架构跟随构建主机
#       （arm64 机器出 arm64 包，x64 机器出 x64 包）；Linux 同理。
#       macOS/iOS 需 macOS 主机；Android 任意主机可交叉构建；
#       HarmonyOS NEXT 需 OpenHarmony 定制 Flutter SDK，此脚本仅占位提示。
param(
  [string[]]$Platforms = @(),
  [switch]$Installer,
  [switch]$Clean,
  [switch]$RefreshVendor  # 强制重新拉取 vendor（zengate+opencode-ai），否则已存在则复用
)
$ErrorActionPreference = "Continue"
Set-Location (Join-Path $PSScriptRoot "..")

# 版本号单一来源：lib/version.dart
$appVersion = (Select-String -Path "lib\version.dart" -Pattern "kAppVersion = '([^']+)'" | Select-Object -First 1).Matches[0].Groups[1].Value
if (-not $appVersion) { $appVersion = "0.0.0" }
Write-Host "版本: $appVersion" -ForegroundColor Cyan

# 真实硬件架构（环境变量在 ARM Windows 的 x64 模拟层下会误报 AMD64）
$winArch = if ((Get-CimInstance Win32_Processor).Architecture -eq 12) { "arm64" } elseif ("$env:PROCESSOR_ARCHITECTURE$env:PROCESSOR_ARCHITEW6432" -match "ARM") { "arm64" } else { "x64" }
Write-Host "构建主机架构: $winArch"

$Matrix = [ordered]@{
  "windows"       = @{ Cmd = @("flutter","build","windows","--release"); Host = "win"; Out = "build\windows\$winArch\runner\Release" }
  "windows-x64"   = @{ Cmd = @("flutter","build","windows","--release"); Host = "win"; Out = "build\windows\x64\runner\Release";   Note = "需在 x64 Windows 上构建" }
  "windows-arm64" = @{ Cmd = @("flutter","build","windows","--release"); Host = "win"; Out = "build\windows\arm64\runner\Release"; Note = "需在 arm64 Windows 上构建" }
  "linux-x64"     = @{ Cmd = @("flutter","build","linux","--release","--target-platform","linux-x64");   Host = "linux"; Out = "build/linux/x64/release/bundle" }
  "linux-arm64"   = @{ Cmd = @("flutter","build","linux","--release","--target-platform","linux-arm64"); Host = "linux"; Out = "build/linux/arm64/release/bundle" }
  "macos"         = @{ Cmd = @("flutter","build","macos","--release"); Host = "macos"; Out = "build/macos/Build/Products/Release" }
  "ios"           = @{ Cmd = @("flutter","build","ios","--release","--no-codesign"); Host = "macos"; Out = "build/ios/iphoneos" }
  "android"       = @{ Cmd = @("flutter","build","apk","--release"); Host = "any"; Out = "build\app\outputs\flutter-apk" }
  "harmony"       = @{ Cmd = @(); Host = "harmony"; Out = "" }
}

function Get-HostKind {
  if ($IsWindows -or ($env:OS -match "Windows")) { "win" }
  elseif ($IsMacOS) { "macos" }
  elseif ($IsLinux) { "linux" }
  else { "win" }
}
$hostKind = Get-HostKind

if (-not $Platforms -or $Platforms.Count -eq 0) {
  Write-Host "可选构建平台（本机为 $hostKind / $winArch）:" -ForegroundColor Cyan
  $i = 1
  foreach ($k in $Matrix.Keys) {
    $t = $Matrix[$k]
    $mark = if ($t.Host -in @("any", $hostKind)) { "" } else { "  [需 $($t.Host) 主机]" }
    Write-Host ("  {0}) {1}{2}" -f $i, $k, $mark)
    $i++
  }
  $sel = Read-Host "输入编号(逗号分隔)或 all，回车取消"
  if (-not $sel) { exit 0 }
  if ($sel -eq "all") { $Platforms = @($Matrix.Keys) }
  else {
    $Platforms = @($sel -split "[,\s]+" | Where-Object { $_ } | ForEach-Object {
      $n = [int]$_; $k = @($Matrix.Keys)[$n - 1]; if (-not $k) { throw "无效编号 $_" }; $k })
  }
}

$failed = @()
$skipped = @()

foreach ($p in $Platforms) {
  $t = $Matrix[$p]
  if (-not $t) { Write-Host "未知平台: $p" -ForegroundColor Yellow; $failed += $p; continue }
  if ($t.Host -eq "harmony") {
    Write-Host "`n== ${p}: 需 OpenHarmony 定制 Flutter SDK，暂未配置 ==" -ForegroundColor Yellow
    $skipped += $p; continue
  }
  if ($t.Host -notin @("any", $hostKind)) {
    Write-Host "`n== ${p}: 需在 $($t.Host) 主机构建，本机($hostKind)跳过 ==" -ForegroundColor Yellow
    $skipped += $p; continue
  }
  if ($t.Note -and $t.Note -notmatch $winArch) {
    Write-Host "`n== ${p}: $($t.Note)，本机为 $winArch，跳过 ==" -ForegroundColor Yellow
    $skipped += $p; continue
  }
  Write-Host "`n== 构建 $p ==" -ForegroundColor Cyan
  if ($Clean) { flutter clean }
  flutter $t.Cmd[1..($t.Cmd.Count - 1)]
  if ($LASTEXITCODE -eq 0) {
    Write-Host "  产物: $t.Out" -ForegroundColor Green
    if ($Installer -and $p -like "windows*") {
      # vendor（zengate + 匹配架构的 opencode-ai）随安装包分发，装好即用；
      # 首次或 -RefreshVendor 时重新准备。版本红线（opencode-ai 必须 ≥1.19.3：
      # 旧内置目录列不出新免费模型；v2 健康检查不兼容）——详见 vendor.ps1 头部。
      if ($RefreshVendor -or -not (Test-Path "vendor\zengate\index.js")) {
        powershell -File tool\vendor.ps1
        if ($LASTEXITCODE -ne 0) { Write-Host "  vendor 准备失败" -ForegroundColor Red; $failed += "$p-vendor"; continue }
      }
      $vendorDest = Join-Path $t.Out "vendor"
      if (Test-Path $vendorDest) { Remove-Item -Recurse -Force $vendorDest }  # 避免重复构建套嵌 vendor\vendor
      Copy-Item -Recurse -Force vendor $vendorDest
      $arch = if ($p -eq "windows-x64") { "x64" } elseif ($p -eq "windows-arm64") { "arm64" } else { $winArch }
      $iscc = @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
      if ($iscc) {
        & $iscc "/DMyArch=$arch" "/DMyVersion=$appVersion" "packaging\zeroapi.iss"
        if ($LASTEXITCODE -eq 0) {
          Write-Host "  安装包: installer\zeroapi-setup-$arch-$appVersion.exe" -ForegroundColor Green
        } else { $failed += "$p-installer" }
      } else {
        Write-Host "  未找到 ISCC.exe（Inno Setup），跳过安装包" -ForegroundColor Yellow
        $failed += "$p-installer"
      }
    }
  } else {
    Write-Host "  构建失败: $p (exit $LASTEXITCODE)" -ForegroundColor Red
    $failed += $p
  }
}

Write-Host "`n==== 汇总 ====" -ForegroundColor Cyan
Write-Host "跳过: $($skipped -join ', ')"
Write-Host "失败: $($failed -join ', ')"
if ($failed.Count -gt 0) { exit 1 }
