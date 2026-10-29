# 静默覆盖安装 ZeroApi（无人值守，无向导、无点击）。
#
# 用法:
#   powershell -NoProfile -File tool\install.ps1                 # 安装 installer\ 下最新的包
#   powershell -NoProfile -File tool\install.ps1 -Setup path.exe # 指定安装包
#   powershell -NoProfile -File tool\install.ps1 -NoLaunch       # 装完不启动
#
# 为什么必须走这个脚本：从 Git Bash 直接执行安装包时，MSYS 会把 /VERYSILENT
# 这类参数改写成 C:/Program Files/Git/VERYSILENT，安装器识别不到静默参数，
# 结果每次都弹出安装向导要求手动点击。Start-Process 传参不经过路径转换。
param(
  [string]$Setup = "",
  [switch]$NoLaunch
)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

if (-not $Setup) {
  $Setup = Get-ChildItem "installer\zeroapi-setup-*.exe" |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Setup -or -not (Test-Path $Setup)) {
  Write-Host "未找到安装包（installer\zeroapi-setup-*.exe）" -ForegroundColor Red
  exit 1
}
Write-Host "安装包: $Setup" -ForegroundColor Cyan
$proc = Start-Process -FilePath $Setup -Wait -PassThru -ArgumentList @(
  '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/FORCECLOSEAPPLICATIONS')
if ($proc.ExitCode -ne 0) {
  Write-Host "安装失败（退出码 $($proc.ExitCode)）" -ForegroundColor Red
  exit $proc.ExitCode
}
Write-Host "安装完成" -ForegroundColor Green
if (-not $NoLaunch) {
  Start-Sleep -Seconds 2
  if (-not (Get-Process -Name "zeroapi" -ErrorAction SilentlyContinue)) {
    $exe = Join-Path $env:ProgramFiles "ZeroApi\zeroapi.exe"
    if (-not (Test-Path $exe)) {
      $exe = Join-Path $env:LOCALAPPDATA "Programs\ZeroApi\zeroapi.exe"
    }
    if (Test-Path $exe) { Write-Host "启动: $exe" -ForegroundColor Cyan; Start-Process $exe }
  } else {
    Write-Host "应用已由安装器自动重启" -ForegroundColor Green
  }
}
