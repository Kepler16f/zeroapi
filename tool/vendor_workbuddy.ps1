# Download the pinned WorkBuddy hub portable runtime into vendor\workbuddy2api-hub.
# The package bundles a trimmed CPython runtime, so the app does not need Python
# installed on the user's machine. vendor\ is gitignored; the build script calls
# this automatically when the runtime is missing.
#
# ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 using the ANSI code
# page unless the file has a BOM.
param([switch]$Force)
$ErrorActionPreference = "Stop"

$Version = "1.7.30"
$Sha256 = "61bb6315f1a7d8f3fc2f7745e6c58f4f4b24d9e0d61bf7b7a6cfa74922f01b1f"
$Url = "https://github.com/ardeyouxipianyi/workbuddy2api-hub/releases/download/v$Version/workbuddy2api-hub-v$Version.zip"

$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root "vendor\workbuddy2api-hub"
$cache = Join-Path $root "vendor\.cache\workbuddy2api-hub-v$Version.zip"
$tmp = Join-Path $env:TEMP "zeroapi-wb-$Version"

if ((Test-Path (Join-Path $dest "python\pythonw.exe")) -and -not $Force) {
  Write-Host "WorkBuddy runtime already present: $dest" -ForegroundColor Green
  exit 0
}

New-Item -ItemType Directory -Force -Path (Split-Path $cache) | Out-Null
if (-not (Test-Path $cache) -or $Force) {
  Write-Host "Downloading $Url"
  Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $cache
}

$actual = (Get-FileHash -Path $cache -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $Sha256) {
  Remove-Item $cache -Force -ErrorAction SilentlyContinue
  throw "SHA256 mismatch: expected $Sha256, got $actual"
}
Write-Host "SHA256 OK"

if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
Expand-Archive -Path $cache -DestinationPath $tmp -Force
if (-not (Test-Path (Join-Path $tmp "wb-proxy\wb_proxy.py"))) {
  throw "Unexpected package layout: wb-proxy\wb_proxy.py not found"
}

if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
Move-Item (Join-Path $tmp "wb-proxy") $dest
Remove-Item -Recurse -Force $tmp

if (-not (Test-Path (Join-Path $dest "python\pythonw.exe"))) {
  throw "Bundled Python runtime missing after extraction"
}
Write-Host "Installed WorkBuddy runtime v$Version -> $dest" -ForegroundColor Green
