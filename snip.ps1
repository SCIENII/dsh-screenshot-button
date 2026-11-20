param(
  [Parameter(Mandatory = $true)][string]$Out,
  [switch]$Full,
  [switch]$Test,
  [switch]$Probe,
  [switch]$NoClipboard
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SnipDpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
try { [SnipDpi]::SetProcessDPIAware() | Out-Null } catch { }

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen

function New-ScreenShot {
  $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size) } finally { $g.Dispose() }
  return $bmp
}

function Get-SelectionRect($a, $b) {
  $x = [Math]::Min($a.X, $b.X)
  $y = [Math]::Min($a.Y, $b.Y)
  $w = [Math]::Abs($a.X - $b.X)
  $h = [Math]::Abs($a.Y - $b.Y)
  return New-Object System.Drawing.Rectangle($x, $y, $w, $h)
}

function Save-Crop($shot, $rect) {
  $clamped = [System.Drawing.Rectangle]::Intersect($rect, (New-Object System.Drawing.Rectangle(0, 0, $shot.Width, $shot.Height)))
  if ($clamped.Width -lt 4 -or $clamped.Height -lt 4) { return $null }
  return $shot.Clone($clamped, $shot.PixelFormat)
}

function Set-ClipboardImage($image) {
  for ($i = 0; $i -lt 4; $i++) {
    try {
      [System.Windows.Forms.Clipboard]::SetImage($image)
      return $true
    } catch {
      Start-Sleep -Milliseconds 120
    }
  }
  return $false
}

$script:shot = New-ScreenShot
$script:start = $null
$script:cur = $null
$script:accepted = $false

if ($Test) {
  $script:accepted = $true
  $script:start = New-Object System.Drawing.Point(60, 60)
  $script:cur = New-Object System.Drawing.Point(460, 360)
}
elseif ($Full) {
  $script:accepted = $true
}
else {
  $veil = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(110, 0, 0, 0))
  $edge = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 36, 123, 191)), 2
  $clear = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Transparent)
  $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
  $label = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 255, 255, 255))
  $labelBack = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(190, 0, 0, 0))

  $form = New-Object System.Windows.Forms.Form
  $form.FormBorderStyle = 'None'
  $form.StartPosition = 'Manual'
  $form.Bounds = $vs
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.KeyPreview = $true
  $form.Cursor = [System.Windows.Forms.Cursors]::Cross
  $form.BackColor = [System.Drawing.Color]::Black

  # DoubleBuffered 是 Control 的 protected 属性，直接 $form.DoubleBuffered = $true
  # 会抛 PropertyAssignmentException，必须走反射设置。
  try {
    $dbProp = [System.Windows.Forms.Control].GetProperty(
      'DoubleBuffered',
      [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
    )
    if ($dbProp) { $dbProp.SetValue($form, $true, $null) }
  } catch { }

  $form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $w = $script:shot.Width
    $h = $script:shot.Height
    $g.DrawImage($script:shot, 0, 0, $w, $h)
    if ($script:start -and $script:cur) {
      $r = Get-SelectionRect $script:start $script:cur
      if ($r.Width -gt 0 -and $r.Height -gt 0) {
        $g.FillRectangle($veil, 0, 0, $w, $r.Top)
        $g.FillRectangle($veil, 0, $r.Bottom, $w, [Math]::Max(0, $h - $r.Bottom))
        $g.FillRectangle($veil, 0, $r.Top, $r.Left, $r.Height)
        $g.FillRectangle($veil, $r.Right, $r.Top, [Math]::Max(0, $w - $r.Right), $r.Height)
        $g.DrawRectangle($edge, $r.Left, $r.Top, $r.Width, $r.Height)
      }
    } else {
      $g.FillRectangle($veil, 0, 0, $w, $h)
    }
    $hint = '拖动鼠标选择截图区域，Esc 取消'
    $size = $g.MeasureString($hint, $font)
    $hx = [Math]::Round(($w - $size.Width) / 2)
    $g.FillRectangle($labelBack, $hx - 12, 28, $size.Width + 24, $size.Height + 12)
    $g.DrawString($hint, $font, $label, $hx, 34)
  })

  $form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $script:start = New-Object System.Drawing.Point($e.X, $e.Y)
      $script:cur = New-Object System.Drawing.Point($e.X, $e.Y)
      $s.Invalidate()
    }
  })
  $form.Add_MouseMove({
    param($s, $e)
    if ($script:start) {
      $script:cur = New-Object System.Drawing.Point($e.X, $e.Y)
      $s.Invalidate()
    }
  })
  $form.Add_MouseUp({
    param($s, $e)
    if ($script:start -and $e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $script:cur = New-Object System.Drawing.Point($e.X, $e.Y)
      $script:accepted = $true
      $s.Close()
    }
  })
  $form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
      $script:accepted = $false
      $s.Close()
    }
  })
  $form.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
      $script:accepted = $false
      $s.Close()
    }
  })
  $form.Add_Shown({
    $form.Activate()
    $form.Focus() | Out-Null
    if ($Probe) {
      # 无人工干预地跑完整覆盖层流程：第一拍画出选框，第二拍接受并关闭。
      $script:probeTick = 0
      $script:probeTimer = New-Object System.Windows.Forms.Timer
      $script:probeTimer.Interval = 400
      $script:probeTimer.Add_Tick({
        $script:probeTick++
        if ($script:probeTick -eq 1) {
          $script:start = New-Object System.Drawing.Point(60, 60)
          $script:cur = New-Object System.Drawing.Point(460, 360)
          $form.Invalidate()
        } else {
          $script:probeTimer.Stop()
          $script:accepted = $true
          $form.Close()
        }
      })
      $script:probeTimer.Start()
    }
    $script:timeout = New-Object System.Windows.Forms.Timer
    $script:timeout.Interval = 180000
    $script:timeout.Add_Tick({
      $script:accepted = $false
      $script:timeout.Stop()
      $form.Close()
    })
    $script:timeout.Start()
  })

  [System.Windows.Forms.Application]::EnableVisualStyles()
  [System.Windows.Forms.Application]::Run($form)
  $form.Dispose()
}

if (-not $script:accepted) {
  $script:shot.Dispose()
  Write-Output 'CANCEL'
  exit 0
}

if ($Full) {
  $result = $script:shot
} else {
  $rect = Get-SelectionRect $script:start $script:cur
  $result = Save-Crop $script:shot $rect
}

if ($null -eq $result) {
  $script:shot.Dispose()
  Write-Output 'CANCEL'
  exit 0
}

$dir = [System.IO.Path]::GetDirectoryName($Out)
if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
$result.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$copied = $false
if (-not $NoClipboard) { $copied = Set-ClipboardImage $result }
if (-not [object]::ReferenceEquals($result, $script:shot)) { $result.Dispose() }
$script:shot.Dispose()

Write-Output "OK:$Out"
Write-Output ("COPIED:" + $copied.ToString().ToLowerInvariant())
