# Renders the "Hub Ring" (方案 C) app icon in multiple sizes + a multi-size .ico
# Geometry mirrors the 120x120 viewBox of the approved design.
param(
  [string]$OutDir = "C:\dev\polygate_app\assets\icon"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$Sizes = @(16, 24, 32, 48, 64, 128, 256, 512, 1024)

function Draw-Icon([int]$px) {
  $bmp = New-Object System.Drawing.Bitmap($px, $px, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $s = $px / 120.0

  # rounded-square clip (radius 26/120, matching the approved design)
  $rr = 26.0 * $s
  $pathObj = New-Object System.Drawing.Drawing2D.GraphicsPath
  $pathObj.AddArc(0, 0, [single](2*$rr), [single](2*$rr), 180, 90)
  $pathObj.AddArc($px - 2*$rr, 0, [single](2*$rr), [single](2*$rr), 270, 90)
  $pathObj.AddArc($px - 2*$rr, $px - 2*$rr, [single](2*$rr), [single](2*$rr), 0, 90)
  $pathObj.AddArc(0, $px - 2*$rr, [single](2*$rr), [single](2*$rr), 90, 90)
  $pathObj.CloseFigure()
  $g.SetClip($pathObj, [System.Drawing.Drawing2D.CombineMode]::Replace)
  $pathObj.Dispose()

  # gradient background (4F6BED -> 06B6D4, diagonal)
  $rect = New-Object System.Drawing.RectangleF(0, 0, $px, $px)
  $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $rect,
    [System.Drawing.Color]::FromArgb(255, 79, 107, 237),
    [System.Drawing.Color]::FromArgb(255, 6, 182, 212),
    [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal)
  $g.FillRectangle($brush, 0, 0, $px, $px)
  $brush.Dispose()

  $cx = 60.0 * $s; $cy = 60.0 * $s; $r = 30.0 * $s

  # ring stroke (white 45%, width 4)
  $penRing = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(115, 255, 255, 255), (4.0 * $s))
  $g.DrawEllipse($penRing, [single]($cx - $r), [single]($cy - $r), [single](2 * $r), [single](2 * $r))
  $penRing.Dispose()

  # spokes (white 85%, width 3)
  $penSpoke = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(217, 255, 255, 255), [single](3.0 * $s))
  $penSpoke.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $penSpoke.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  foreach ($deg in @(-90, -30, 30, 90, 150, 210)) {
    $rad = $deg * [Math]::PI / 180.0
    $ex = $cx + $r * [Math]::Cos($rad); $ey = $cy + $r * [Math]::Sin($rad)
    $g.DrawLine($penSpoke, [single]$cx, [single]$cy, [single]$ex, [single]$ey)
  }
  $penSpoke.Dispose()

  # nodes: center r9, outer r5.5 (solid white)
  $wb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
  $g.FillEllipse($wb, [single]($cx - 9 * $s), [single]($cy - 9 * $s), [single](18 * $s), [single](18 * $s))
  foreach ($deg in @(-90, -30, 30, 90, 150, 210)) {
    $rad = $deg * [Math]::PI / 180.0
    $ex = $cx + $r * [Math]::Cos($rad); $ey = $cy + $r * [Math]::Sin($rad)
    $g.FillEllipse($wb, [single]($ex - 5.5 * $s), [single]($ey - 5.5 * $s), [single](11 * $s), [single](11 * $s))
  }
  $wb.Dispose()
  $g.Dispose()
  return $bmp
}

foreach ($px in $Sizes) {
  $bmp = Draw-Icon $px
  $path = Join-Path $OutDir "icon_$px.png"
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host "wrote $path"
}

# Build multi-size .ico from PNG frames (PNG-compressed entries, Vista+ format)
$IcoSizes = @(16, 24, 32, 48, 64, 128, 256)
$frames = foreach ($px in $IcoSizes) {
  $tmp = Join-Path $env:TEMP ("ico_$px.png")
  $bmp = Draw-Icon $px
  $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  [PSCustomObject]@{ Px = $px; Bytes = [System.IO.File]::ReadAllBytes($tmp) }
  Remove-Item $tmp
}
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
  $dim = if ($f.Px -ge 256) { 0 } else { $f.Px }
  $bw.Write([Byte]$dim); $bw.Write([Byte]$dim)
  $bw.Write([Byte]0); $bw.Write([Byte]0)
  $bw.Write([UInt16]1); $bw.Write([UInt16]32)
  $bw.Write([UInt32]$f.Bytes.Length); $bw.Write([UInt32]$offset)
  $offset += $f.Bytes.Length
}
foreach ($f in $frames) { $bw.Write($f.Bytes) }
$bw.Flush()
$icoPath = Join-Path $OutDir "zeroapi.ico"
[System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()
Write-Host "wrote $icoPath ($((Get-Item $icoPath).Length) bytes, frames: $($IcoSizes -join ','))"
