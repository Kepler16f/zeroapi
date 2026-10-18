# 准备随包分发的 vendor 目录（zengate + 匹配架构的 opencode-ai）
# 用法: powershell -File tool\vendor.ps1 [-OpencodeVersion <1.x>]
# 产物: vendor\zengate\  （含 node_modules，installer 打包进 app 目录，开箱即用）
# 说明:
#   - zengate 取 npm 最新版；opencode-ai 默认 1.19.3，npm 按平台规则自动装出
#     匹配当前架构（x64/arm64）的 optionalDependencies 二进制 —— 在哪个架构
#     主机上打包，就出哪个架构的 vendor，与安装包架构一致
#   - 版本红线（2026-10-18 实测）：
#     * 内置目录快照决定"可 keyless 的免费模型"子集：<1.19 的快照太旧，列不出
#       deepseek-v4.1-flash-free / glm-5.3-flash-free 等新免费模型（只有 8 个），
#       无论 models.dev 拉到多新都不会补进子集 —— 勿降级到 1.18.x！
#     * v2.x 因 /health 返回 HTML 与 zengate 健康检查不兼容，禁用。
#     * 高频测试同一版本会触发 Zen 按客户端指纹分窗限流（"free tier can only be
#       used from within OpenCode"），冷却数十分钟自愈——勿误判为版本坏。
#   - PowerShell 5.1 注意：npm 会往 stderr 写 notice，ErrorActionPreference=Stop
#     会把它们变成 NativeCommandError 终止脚本——全程 Continue，用退出码判断
param(
  [string]$OpencodeVersion = "1.19.3"
)
$ErrorActionPreference = "Continue"
Set-Location (Join-Path $PSScriptRoot "..")

function Invoke-Checked($what, [scriptblock]$block) {
  $out = & $block 2>$null
  if ($LASTEXITCODE -ne 0) { throw "$what 失败 (exit $LASTEXITCODE): $($out -join ' ')" }
  return $out
}

$zengateVer = (Invoke-Checked "npm view zengate version" { npm view zengate version }).Trim()
if (-not $zengateVer) { throw "npm view zengate version 无输出" }
Write-Host "zengate@$zengateVer -> vendor\ (+ opencode-ai pin)" -ForegroundColor Cyan

if (Test-Path vendor) { Remove-Item -Recurse -Force vendor }
New-Item -ItemType Directory -Path vendor | Out-Null

# npm pack 拿到的就是发布产物本身（含 src/ 与 package.json，不含 node_modules）
Invoke-Checked "npm pack zengate" { npm pack "zengate@$zengateVer" --pack-destination vendor } | Out-Null
$tgz = Get-ChildItem vendor -Filter "*.tgz" | Select-Object -First 1
if (-not $tgz) { throw "npm pack zengate 失败: 无 tgz" }
# 必须用 System32 的 bsdtar 且传相对文件名：PATH 里若存在 Git-Bash tar，
# 它会把 "C:\..." 误解析成远程 host "C:"（Cannot connect to C: resolve failed）
$tarExe = Join-Path $env:SystemRoot "System32\tar.exe"
Push-Location vendor
Invoke-Checked "解压 tgz" { & $tarExe -xzf $tgz.Name -C . } | Out-Null
Pop-Location
Move-Item (Join-Path $tgz.DirectoryName "package") (Join-Path $tgz.DirectoryName "zengate")
Remove-Item $tgz.FullName

# 装运行依赖；opencode-ai 钉到 $OpencodeVersion（默认 1.19.3，见头部版本红线：
# 低于 1.19 的内置目录列不出 deepseek/glm 等新免费模型）
Push-Location vendor\zengate
$OcPin = if ($OpencodeVersion) { @("--save-exact", "opencode-ai@$OpencodeVersion") } else { @() }
Invoke-Checked "npm install" { npm install --omit=dev --no-audit --no-fund @OcPin } | Out-Null
Pop-Location

# 自检：入口与 opencode 二进制必须存在。
# opencode-ai 的 bin/opencode.exe 是 postinstall 复制出来的（<1MB 的 stub 说明
# install scripts 被 allowScripts/npm 配置拦截未跑）——直接从平台包补齐，
# 平台包名含当前主机架构（windows-arm64 / windows-x64），与安装包架构一致。
foreach ($f in @("vendor\zengate\index.js", "vendor\zengate\node_modules\opencode-ai\bin\opencode.exe")) {
  if (-not (Test-Path $f)) { throw "vendor 自检失败: 缺 $f" }
}
$ocBin = "vendor\zengate\node_modules\opencode-ai\bin\opencode.exe"
if ((Get-Item $ocBin).Length -lt 1MB) {
  # 不猜架构（ARM Windows 的 x64 模拟层会误报）：npm 已按本机真实架构装出
  # 对应的平台包（optionalDependencies），直接找它
  $platDir = Get-ChildItem "vendor\zengate\node_modules" -Directory -Filter "opencode-*" |
    Where-Object { Test-Path (Join-Path $_.FullName "bin\opencode.exe") } |
    Select-Object -First 1
  if (-not $platDir) { throw "vendor 自检失败: 是 stub 且没有可用平台包（npm 需在目标架构主机运行以安装 optionalDependencies）" }
  Copy-Item -Force (Join-Path $platDir.FullName "bin\opencode.exe") $ocBin
  Write-Host "  postinstall 未跑：已从 $($platDir.Name) 复制真二进制" -ForegroundColor Yellow
}
$ocActual = (Get-Content vendor\zengate\node_modules\opencode-ai\package.json | ConvertFrom-Json).version
'{"zengate":"' + $zengateVer + '","opencode-ai":"' + $ocActual + '","built":"' + (Get-Date -Format yyyy-MM-dd) + '"}' | Out-File vendor\manifest.json -Encoding ascii
Write-Host "vendor 就绪: zengate@$zengateVer opencode-ai@$ocActual" -ForegroundColor Green
