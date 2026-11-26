param(
  [Parameter(Mandatory = $true)][string]$Out,
  [ValidateSet('region', 'full')][string]$Mode = 'region',
  [ValidateSet('auto', 'native', 'overlay')][string]$Engine = 'auto',
  [int]$TimeoutSec = 120,
  [switch]$NoClipboard,
  [switch]$Test,
  [switch]$Probe
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SnipWin {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  public const uint LEFTDOWN = 0x0002;
  public const uint LEFTUP = 0x0004;
}
"@
try { [SnipWin]::SetProcessDPIAware() | Out-Null } catch { }

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen

function New-ScreenShot {
  $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size) } finally { $g.Dispose() }
  return $bmp
}

function Get-SelectionRect($a, $b) {
  return New-Object System.Drawing.Rectangle(
    [Math]::Min($a.X, $b.X), [Math]::Min($a.Y, $b.Y),
    [Math]::Abs($a.X - $b.X), [Math]::Abs($a.Y - $b.Y))
}

function Save-Crop($shot, $rect) {
  $clamped = [System.Drawing.Rectangle]::Intersect($rect, (New-Object System.Drawing.Rectangle(0, 0, $shot.Width, $shot.Height)))
  if ($clamped.Width -lt 4 -or $clamped.Height -lt 4) { return $null }
  return $shot.Clone($clamped, $shot.PixelFormat)
}

function Get-ClipboardImage {
  if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { return $null }
  try { return [System.Windows.Forms.Clipboard]::GetImage() } catch { return $null }
}

# Put the capture on the clipboard in two shapes at once: as a bitmap (classic
# paste) and as a file drop list (so the composer's file-paste router takes it
# even when no file item is synthesized from a bare bitmap).
function Set-ClipboardCapture($image, $path) {
  for ($i = 0; $i -lt 5; $i++) {
    try {
      $payload = New-Object System.Windows.Forms.DataObject
      $payload.SetImage($image)
      if ($path) {
        $list = New-Object System.Collections.Specialized.StringCollection
        $list.Add($path) | Out-Null
        $payload.SetFileDropList($list)
      }
      [System.Windows.Forms.Clipboard]::SetDataObject($payload, $true)
      return $true
    } catch {
      Start-Sleep -Milliseconds 150
    }
  }
  return $false
}

function Save-Image($image, $path) {
  $dir = [System.IO.Path]::GetDirectoryName($path)
  if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
  $image.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
}

# --- native engine: let the Windows snipper do the overlay -------------------
# Start-Process goes through ShellExecute, which activates the AppX protocol
# registered for ms-screenclip:. That is the same overlay Win+Shift+S shows,
# so there is no window of ours to fight for focus, activation or DPI.

function Invoke-NativeSnipper {
  $known = @(Get-Process SnippingTool -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

  if ($Test -or $Probe) {
    Start-Process 'ms-screenclip:'
  } else {
    Start-Process 'ms-screenclip:'
  }

  # Wait for the overlay process to appear so a synthetic drag lands on it.
  $deadline = (Get-Date).AddSeconds(8)
  while ((Get-Date) -lt $deadline) {
    $live = @(Get-Process SnippingTool -ErrorAction SilentlyContinue | Where-Object { $known -notcontains $_.Id })
    if ($live.Count -gt 0) { break }
    Start-Sleep -Milliseconds 100
  }

  if ($Probe) {
    # Drive a rectangle through the overlay the same way a mouse would.
    Start-Sleep -Milliseconds 900
    [SnipWin]::SetCursorPos(240, 240) | Out-Null
    Start-Sleep -Milliseconds 200
    [SnipWin]::mouse_event([SnipWin]::LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    for ($step = 1; $step -le 12; $step++) {
      [SnipWin]::SetCursorPos(240 + [int](620 * $step / 12), 240 + [int](400 * $step / 12)) | Out-Null
      Start-Sleep -Milliseconds 45
    }
    Start-Sleep -Milliseconds 200
    [SnipWin]::mouse_event([SnipWin]::LEFTUP, 0, 0, 0, [IntPtr]::Zero)
  }

  $clock = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $clock) {
    if ([SnipWin]::GetClipboardSequenceNumber() -ne $script:seq) {
      # Clipboard changed: give the snipper a moment to finish writing.
      Start-Sleep -Milliseconds 260
      $image = Get-ClipboardImage
      if ($image) { return $image }
    }
    $stillOpen = @(Get-Process SnippingTool -ErrorAction SilentlyContinue | Where-Object { $known -notcontains $_.Id })
    if ($stillOpen.Count -eq 0 -and [SnipWin]::GetClipboardSequenceNumber() -eq $script:seq) {
      Start-Sleep -Milliseconds 300
      if ([SnipWin]::GetClipboardSequenceNumber() -eq $script:seq) { return $null }
    }
    Start-Sleep -Milliseconds 120
  }
  return $null
}

# --- overlay engine: our own full-screen rubber band ------------------------

function Invoke-OverlaySnipper {
  $shot = New-ScreenShot
  $script:overlayShot = $shot
  if ($Test) {
    return (Save-Crop $shot (New-Object System.Drawing.Rectangle(60, 60, 400, 300)))
  }

  $veil = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(110, 0, 0, 0))
  $edge = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 36, 123, 191)), 2
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

  # DoubleBuffered is protected; assigning it directly throws PropertyAssignmentException.
  try {
    $prop = [System.Windows.Forms.Control].GetProperty(
      'DoubleBuffered',
      [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
    if ($prop) { $prop.SetValue($form, $true, $null) }
  } catch { }

  $form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $w = $script:overlayShot.Width
    $h = $script:overlayShot.Height
    $g.DrawImage($script:overlayShot, 0, 0, $w, $h)
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
    $hint = '拖动鼠标选择区域，Esc 取消'
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

  if (-not $script:accepted) { return $null }
  if (-not $script:start -or -not $script:cur) { return $null }
  return (Save-Crop $shot (Get-SelectionRect $script:start $script:cur))
}

# --- entry -----------------------------------------------------------------

$script:overlayShot = $null
$script:start = $null
$script:cur = $null
$script:accepted = $false
$script:seq = [SnipWin]::GetClipboardSequenceNumber()

if ($Mode -eq 'full') {
  $result = New-ScreenShot
} else {
  $engine = $Engine
  if ($engine -eq 'auto') {
    # The native snipper needs the AppX protocol; fall back when it is absent.
    $engine = if ((Get-Command Start-Process) -and (Test-Path 'Registry::HKEY_CLASSES_ROOT\ms-screenclip')) { 'native' } else { 'overlay' }
  }
  $result = if ($engine -eq 'native') { Invoke-NativeSnipper } else { Invoke-OverlaySnipper }
}

if ($null -eq $result) {
  if ($script:overlayShot) { $script:overlayShot.Dispose() }
  Write-Output 'CANCEL'
  exit 0
}

Save-Image $result $Out
$copied = $false
if (-not $NoClipboard) { $copied = Set-ClipboardCapture $result $Out }
if (-not [object]::ReferenceEquals($result, $script:overlayShot)) { $result.Dispose() }
if ($script:overlayShot) { $script:overlayShot.Dispose() }

Write-Output "OK:$Out"
Write-Output ("COPIED:" + $copied.ToString().ToLowerInvariant())
