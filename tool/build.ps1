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
  [switch]$Install,
  [switch]$Clean
)
$ErrorActionPreference = "Continue"
Set-Location (Join-Path $PSScriptRoot "..")

# flutter 必须显式入 PATH：从 Git Bash / 精简环境启动 powershell 时 PATH 里
# 没有 flutter，命令找不到会被 $ErrorActionPreference=Continue 吞掉，
# 随后 ISCC 会把上一次的旧产物打进安装包（0.2.1 曾这样静默产出过旧包）。
# 优先 arm64 引擎的 SDK（本机 ARM Windows，安装包也是 arm64）；SDK 曾从
# C:\flutter 迁到 C:\dev\flutter-arm64，逐个探测。
$flutterHomes = @("C:\dev\flutter-arm64\bin", "C:\flutter\bin", "C:\dev\flutter\bin")
$flutterHome = $flutterHomes | Where-Object { Test-Path (Join-Path $_ "flutter.bat") } | Select-Object -First 1
if ($flutterHome) {
  $env:Path = "$flutterHome;" + $env:Path
}
$flutterExe = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutterExe) {
  Write-Host "错误：找不到 flutter（期望 $flutterHome\flutter.bat）" -ForegroundColor Red
  exit 1
}
Write-Host "flutter: $flutterExe"

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
  if ($Clean) {
    & $flutterExe clean
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  构建失败: $p（flutter clean 退出码 $LASTEXITCODE）" -ForegroundColor Red
      $failed += $p; continue
    }
  }
  $buildArgs = @($t.Cmd[1..($t.Cmd.Count - 1)])
  & $flutterExe @buildArgs
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  构建失败: $p（flutter 退出码 $LASTEXITCODE）" -ForegroundColor Red
    $failed += $p; continue
  }
  # 新鲜度校验：产物必须不早于其源码的最新修改时间。曾因 flutter 命令
  # 未执行（PATH 缺失被吞）而把旧产物重新打成安装包——这里硬性拦下。
  # 判据用源码 mtime 而不是"本次构建开始时间"：只改安装器配置等不触发
  # 重编译的场景不应误报。
  $appSo = Join-Path $t.Out "data\app.so"
  if (-not (Test-Path $appSo)) {
    Write-Host "  构建失败: $p（找不到 $appSo）" -ForegroundColor Red
    $failed += $p; continue
  }
  $dartSrc = Get-ChildItem lib -Recurse -Filter *.dart -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $cfgSrc = @(Get-Item pubspec.yaml, pubspec.lock -ErrorAction SilentlyContinue) |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $dartNewest = @($dartSrc, $cfgSrc) | Where-Object { $_ } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($dartNewest -and (Get-Item $appSo).LastWriteTime -lt $dartNewest.LastWriteTime) {
    Write-Host "  构建失败: $p（app.so 早于最新 Dart 源码 $($dartNewest.Name)，拒绝打包旧产物）" -ForegroundColor Red
    $failed += $p; continue
  }
  $exePath = Join-Path $t.Out "zeroapi.exe"
  $winSrc = Get-ChildItem windows -Recurse -Include *.cpp,*.h,*.cc,*.txt -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ((Test-Path $exePath) -and $winSrc -and
      (Get-Item $exePath).LastWriteTime -lt $winSrc.LastWriteTime) {
    Write-Host "  构建失败: $p（zeroapi.exe 早于最新 Windows 源码 $($winSrc.Name)，拒绝打包旧产物）" -ForegroundColor Red
    $failed += $p; continue
  }
  Write-Host "  产物: $($t.Out)" -ForegroundColor Green
  if ($Installer -and $p -like "windows*") {
      # Zen 免费档由网关原生直连（lib/gateway/zen.dart），无需 zengate vendor。
      # WorkBuddy 号池例外：随包分发 vendor\workbuddy2api-hub（含便携 Python）。
      $wbVendor = Join-Path (Get-Location) "vendor\workbuddy2api-hub"
      if (-not (Test-Path (Join-Path $wbVendor "python\pythonw.exe"))) {
        Write-Host "  准备 WorkBuddy 运行时..." -ForegroundColor Cyan
        try {
          & (Join-Path $PSScriptRoot "vendor_workbuddy.ps1")
        } catch {
          Write-Host "  [警告] 下载 WorkBuddy 运行时失败：$_" -ForegroundColor Yellow
        }
      }
      $vendorDest = Join-Path $t.Out "vendor"
      if (Test-Path $vendorDest) { Remove-Item -Recurse -Force $vendorDest }
      if (Test-Path (Join-Path $wbVendor "python\pythonw.exe")) {
        $wbDest = Join-Path $vendorDest "workbuddy2api-hub"
        New-Item -ItemType Directory -Force -Path $wbDest | Out-Null
        Copy-Item (Join-Path $wbVendor "*") $wbDest -Recurse -Force
        Write-Host "  已打包 WorkBuddy 运行时" -ForegroundColor Green
      } else {
        Write-Host "  [警告] 未找到 WorkBuddy 运行时，安装包不含号池功能" -ForegroundColor Yellow
      }
      # 加密协议（ss/vmess/vless/trojan/hysteria2/tuic）本地内核：随包分发
      # vendor\proxy-core\mihomo.exe（每个节点一个 loopback listener）。
      $coreSrc = Join-Path (Get-Location) "vendor\proxy-core"
      if (Test-Path (Join-Path $coreSrc "mihomo.exe")) {
        $coreDest = Join-Path $vendorDest "proxy-core"
        New-Item -ItemType Directory -Force -Path $coreDest | Out-Null
        Copy-Item (Join-Path $coreSrc "*") $coreDest -Recurse -Force
        Write-Host "  已打包代理内核（mihomo）" -ForegroundColor Green
      } else {
        Write-Host "  [警告] 未找到 vendor\proxy-core\mihomo.exe，加密协议节点将不可用" -ForegroundColor Yellow
      }
      $arch = if ($p -eq "windows-x64") { "x64" } elseif ($p -eq "windows-arm64") { "arm64" } else { $winArch }
      $iscc = @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
      if ($iscc) {
        & $iscc "/DMyArch=$arch" "/DMyVersion=$appVersion" "packaging\zeroapi.iss"
        if ($LASTEXITCODE -eq 0) {
          Write-Host "  安装包: installer\zeroapi-setup-$arch-$appVersion.exe" -ForegroundColor Green
          if ($Install) {
            # 关键：必须经 Start-Process 传参。从 Git Bash 直接调用时 MSYS 会把
            # /VERYSILENT 改写成 C:/Program Files/Git/VERYSILENT，安装器退化成
            # 交互向导（表现为"每次都要手点"）。
            $setup = Join-Path (Get-Location) "installer\zeroapi-setup-$arch-$appVersion.exe"
            if (Test-Path $setup) {
              Write-Host "  静默覆盖安装..." -ForegroundColor Cyan
              $proc = Start-Process -FilePath $setup -Wait -PassThru -ArgumentList @(
                '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/FORCECLOSEAPPLICATIONS')
              if ($proc.ExitCode -eq 0) {
                Write-Host "  已安装（无交互）" -ForegroundColor Green
                # 安装器配置为 RestartApplications=yes；若未自动拉起则手动启动
                Start-Sleep -Seconds 2
                if (-not (Get-Process -Name "zeroapi" -ErrorAction SilentlyContinue)) {
                  $exe = Join-Path $env:ProgramFiles "ZeroApi\zeroapi.exe"
                  if (Test-Path $exe) { Start-Process $exe }
                }
              } else {
                Write-Host "  安装失败（退出码 $($proc.ExitCode)）" -ForegroundColor Red
                $failed += "$p-install"
              }
            }
          }
        } else { $failed += "$p-installer" }
      } else {
        Write-Host "  未找到 ISCC.exe（Inno Setup），跳过安装包" -ForegroundColor Yellow
        $failed += "$p-installer"
      }
  }
}

Write-Host "`n==== 汇总 ====" -ForegroundColor Cyan
Write-Host "跳过: $($skipped -join ', ')"
Write-Host "失败: $($failed -join ', ')"
if ($failed.Count -gt 0) { exit 1 }
