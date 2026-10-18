$ErrorActionPreference = 'Stop'
$sig = @'
using System;
using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
'@
Add-Type -TypeDefinition $sig

$dir = 'C:\dev\polygate_app\build\windows\arm64\runner\Release'
Start-Process -FilePath (Join-Path $dir 'zeroapi.exe')
Start-Sleep -Seconds 12

$p = Get-Process zeroapi -ErrorAction SilentlyContinue
if (-not $p) { Write-Output 'FAIL: not running'; exit 1 }
$h = $p.MainWindowHandle
Write-Output ('started visible=' + [W]::IsWindowVisible($h))

# 关闭 → 应隐藏进托盘
$null = [W]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 2
Write-Output ('after WM_CLOSE visible=' + [W]::IsWindowVisible($h) + ' alive=' + [bool](Get-Process zeroapi -EA SilentlyContinue))

# 模拟托盘双击：kTrayMsg = WM_APP+40, wParam=图标ID(1), lParam=WM_LBUTTONDBLCLK(0x0203)
$null = [W]::PostMessage($h, 0x8028, [IntPtr]1, [IntPtr]0x0203)
Start-Sleep -Seconds 2
Write-Output ('after tray dblclick visible=' + [W]::IsWindowVisible($h))

Stop-Process -Name zeroapi -Force -EA SilentlyContinue
Write-Output 'cleanup done'
