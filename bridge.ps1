# Aseprite Bridge -- drive a live Aseprite GUI instance from the shell.
#
#   pwsh ./bridge.ps1 start                 # launch persistent GUI + agent
#   pwsh ./bridge.ps1 open <file.ase>       # open a sprite
#   pwsh ./bridge.ps1 run  "<lua code>"     # run Lua in Aseprite (returns its value)
#   pwsh ./bridge.ps1 run  "<lua>" -NoWait  # for code that opens a modal dialog
#   pwsh ./bridge.ps1 screenshot <out.png>  # capture the Aseprite window (incl. dialogs)
#   pwsh ./bridge.ps1 key Escape            # send one key (name or char)
#   pwsh ./bridge.ps1 keys "Tab Tab Space Enter"   # send a sequence of keys
#   pwsh ./bridge.ps1 type "hello"          # type literal text into the focused entry
#   pwsh ./bridge.ps1 ping                  # check the agent is alive
#   pwsh ./bridge.ps1 stop                  # quit the instance
#
# The agent is the installed extension at %APPDATA%/Aseprite/extensions/aseprite-bridge
# (run ./install.ps1 once). 'start' self-grants that extension filesystem trust by
# writing its path-hash to aseprite.ini [script_access], and gates it via the
# ASEPRITE_BRIDGE env var so normal Aseprite sessions are unaffected.
param(
  [Parameter(Position = 0)][string]$Command,
  [Parameter(Position = 1)][string]$Arg,
  [switch]$NoWait,
  [int]$TimeoutSec = 25,
  [int]$DelayMs = 60,
  [string]$Aseprite = $env:ASEPRITE_EXE
)
$ErrorActionPreference = "Stop"
if (-not $Aseprite) { $Aseprite = "C:\Users\bluey\aseprite\build\bin\aseprite.exe" }

$Ini       = Join-Path $env:APPDATA "Aseprite\aseprite.ini"
$ExtScript = Join-Path $env:APPDATA "Aseprite\extensions\aseprite-bridge\bridge.lua"
$Bdir      = Join-Path $env:USERPROFILE ".aseprite-bridge"
$CmdDir    = Join-Path $Bdir "cmd"
$ResDir    = Join-Path $Bdir "res"
$PidFile   = Join-Path $Bdir "pid"
$ReadyFile = Join-Path $Bdir "ready"

# --- native window capture (P/Invoke only; Bitmap work stays in PowerShell, since
#     System.Drawing types drag .NET-10 compile-time refs into Add-Type) ---
if (-not ("AseCap" -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Collections;
using System.Runtime.InteropServices;
using System.Text;
public class AseCap {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public class Win { public IntPtr Handle; public int Left,Top,Right,Bottom; public bool Visible; public string Title; }
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll")] public static extern short VkKeyScan(char ch);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  public static Win[] GetWindows(int pid) {
    var list = new ArrayList();
    EnumWindows((h, l) => {
      uint wpid; GetWindowThreadProcessId(h, out wpid);
      if (wpid == (uint)pid) {
        RECT r; GetWindowRect(h, out r);
        int len = GetWindowTextLength(h); var sb = new StringBuilder(len + 1);
        GetWindowText(h, sb, sb.Capacity);
        list.Add(new Win { Handle = h, Left = r.Left, Top = r.Top, Right = r.Right,
          Bottom = r.Bottom, Visible = IsWindowVisible(h), Title = sb.ToString() });
      }
      return true;
    }, IntPtr.Zero);
    return (Win[])list.ToArray(typeof(Win));
  }
}
"@
}

function Get-Sha1Hex([string]$s) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') })
}

function Get-AsePid {
  if (-not (Test-Path $PidFile)) { return $null }
  $p = (Get-Content $PidFile -Raw).Trim()
  if (-not $p) { return $null }
  $proc = Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue
  if ($proc) { return [int]$p } else { return $null }
}

function Ensure-Grant {
  # Aseprite gates script filesystem access; grant the extension full trust (31)
  # by keying on SHA1 of its BACKSLASH absolute path under [script_access].
  $hash = Get-Sha1Hex $ExtScript
  $iniText = Get-Content $Ini -Raw
  if ($iniText -match [regex]::Escape($hash)) { return }
  if ($iniText -match '(?m)^\[script_access\]\s*$') {
    $iniText = $iniText -replace '(?m)^\[script_access\]\s*$', "[script_access]`n$hash = 31"
  } else {
    $iniText = $iniText.TrimEnd() + "`n`n[script_access]`n$hash = 31`n"
  }
  Set-Content -Path $Ini -Value $iniText -NoNewline
}

function Get-MainWindow {
  $asePid = Get-AsePid
  if (-not $asePid) { throw "Aseprite is not running (no live pid). Run 'start' first." }
  $wins = [AseCap]::GetWindows($asePid) | Where-Object { $_.Visible -and ($_.Right - $_.Left) -gt 0 }
  $wins | Sort-Object { ($_.Right-$_.Left)*($_.Bottom-$_.Top) } -Descending | Select-Object -First 1
}

function Capture-To([string]$out) {
  $win = Get-MainWindow
  if (-not $win) { throw "No capturable Aseprite window." }
  Ensure-Restored $win
  $win = Get-MainWindow  # re-read rect after a possible restore
  if (-not [System.IO.Path]::IsPathRooted($out)) { $out = Join-Path (Get-Location) $out }
  Add-Type -AssemblyName System.Drawing
  $w = $win.Right - $win.Left; $h = $win.Bottom - $win.Top
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  [AseCap]::PrintWindow($win.Handle, $hdc, 0x2) | Out-Null   # PW_RENDERFULLCONTENT
  $g.ReleaseHdc($hdc); $g.Dispose()
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host "screenshot -> $out (${w}x${h})"
}

# --- keyboard input (synthetic keystrokes via PostMessage) ---------------------
# laf processes WM_KEYDOWN/WM_KEYUP posted straight to the window handle, so keys
# land WITHOUT stealing foreground (same win as PrintWindow for screenshots). It
# does NOT honour the cross-process keyboard state, so Shift/Ctrl/Alt modifiers and
# uppercase/shifted characters cannot be delivered this way -- see README.
$WM_KEYDOWN = 0x100; $WM_KEYUP = 0x101

# Named keys -> virtual-key code. Case-insensitive; aliases included.
$KeyMap = @{
  enter=0x0D; return=0x0D; tab=0x09; space=0x20; spacebar=0x20; esc=0x1B; escape=0x1B
  backspace=0x08; bksp=0x08; delete=0x2E; del=0x2E; insert=0x2D; ins=0x2D
  up=0x26; down=0x28; left=0x25; right=0x27
  home=0x24; end=0x23; pageup=0x21; pgup=0x21; pagedown=0x22; pgdn=0x22
  f1=0x70; f2=0x71; f3=0x72; f4=0x73; f5=0x74; f6=0x75
  f7=0x76; f8=0x77; f9=0x78; f10=0x79; f11=0x7A; f12=0x7B
}
# Keys that need the extended-key flag set in lParam bit 24.
$ExtKeys = @(0x26,0x28,0x25,0x27,0x24,0x23,0x21,0x22,0x2E,0x2D)

function Resolve-Vk([string]$token) {
  $t = $token.ToLower()
  if ($KeyMap.ContainsKey($t)) { return [int]$KeyMap[$t] }
  if ($token.Length -eq 1) {
    $vks = [AseCap]::VkKeyScan($token[0])
    if ($vks -ne -1) { return ($vks -band 0xFF) }  # low byte = VK (shift bit ignored)
  }
  throw "unknown key token: '$token' (use a letter/digit or a named key like Tab, Enter, Space, Up)"
}

function Send-Vk([IntPtr]$hwnd, [int]$vk, [int]$delayMs) {
  $scan = [AseCap]::MapVirtualKey([uint32]$vk, 0)
  $ext  = if ($ExtKeys -contains $vk) { 0x01000000 } else { 0 }
  $lpDown = [IntPtr](([int64]$scan -shl 16) -bor 1 -bor $ext)
  $lpUp   = [IntPtr](([int64]$scan -shl 16) -bor 0xC0000001 -bor $ext)
  [AseCap]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$vk, $lpDown) | Out-Null
  [AseCap]::PostMessage($hwnd, $WM_KEYUP,   [IntPtr]$vk, $lpUp)   | Out-Null
  Start-Sleep -Milliseconds $delayMs
}

# Un-minimize without activating: laf draws dialogs inside the main window, so a
# minimized window swallows both keystrokes and screenshots.
function Ensure-Restored($win) {
  if ($win -and [AseCap]::IsIconic($win.Handle)) {
    [AseCap]::ShowWindow($win.Handle, 4) | Out-Null  # SW_SHOWNOACTIVATE
    Start-Sleep -Milliseconds 150
  }
}

function Send-Keys([string]$seq, [int]$delayMs) {
  $win = Get-MainWindow
  if (-not $win) { throw "No Aseprite window to send keys to." }
  Ensure-Restored $win
  $tokens = $seq -split '\s+' | Where-Object { $_ -ne '' }
  foreach ($tok in $tokens) { Send-Vk $win.Handle (Resolve-Vk $tok) $delayMs }
  Write-Host "sent keys: $($tokens -join ' ')"
}

function Send-Type([string]$text, [int]$delayMs) {
  $win = Get-MainWindow
  if (-not $win) { throw "No Aseprite window to type into." }
  Ensure-Restored $win
  $shifted = ''
  foreach ($ch in $text.ToCharArray()) {
    $vks = [AseCap]::VkKeyScan($ch)
    if ($vks -eq -1) { continue }
    if (($vks -band 0x100) -ne 0 -and $ch -ne ' ') { $shifted += $ch }  # needs Shift -> unreliable
    Send-Vk $win.Handle ($vks -band 0xFF) $delayMs
  }
  Write-Host "typed: $text"
  if ($shifted) { Write-Host "WARNING: characters '$shifted' need Shift, which PostMessage cannot deliver -- they arrived lowercase/unshifted." }
}

function Send-Command([string]$op, [string]$cmdArg, [switch]$noWait) {
  if (-not (Get-AsePid)) { throw "Aseprite is not running. Run 'start' first." }
  $seq = "{0}_{1}" -f ([DateTimeOffset]::Now.ToUnixTimeMilliseconds()), (Get-Random -Maximum 99999)
  $body = if ($cmdArg) { "$op`n$cmdArg" } else { $op }
  $tmp = Join-Path $CmdDir "$seq.cmd.tmp"
  $final = Join-Path $CmdDir "$seq.cmd"
  Set-Content -Path $tmp -Value $body -NoNewline
  Move-Item -Path $tmp -Destination $final -Force
  if ($noWait) { Write-Host "(no-wait) queued $op"; return }

  $resPath = Join-Path $ResDir "$seq.res"
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while (((Get-Date) -lt $deadline) -and -not (Test-Path $resPath)) { Start-Sleep -Milliseconds 80 }
  if (-not (Test-Path $resPath)) { Write-Host "TIMEOUT waiting for result of '$op'"; return }
  $res = Get-Content $resPath -Raw
  Remove-Item $resPath -ErrorAction SilentlyContinue
  Write-Host $res.TrimEnd()
}

switch ($Command) {
  "start" {
    $existing = Get-AsePid
    if ($existing) { Write-Host "already running (pid $existing)"; break }
    if (-not (Test-Path $ExtScript)) { throw "Extension not installed at $ExtScript -- run ./install.ps1 first." }
    Ensure-Grant
    New-Item -ItemType Directory -Force -Path $Bdir, $CmdDir, $ResDir | Out-Null
    Get-ChildItem $CmdDir, $ResDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item $ReadyFile -ErrorAction SilentlyContinue
    $env:ASEPRITE_BRIDGE = "1"
    $env:ASEPRITE_BRIDGE_DIR = $Bdir
    $proc = Start-Process -FilePath $Aseprite -PassThru
    Set-Content -Path $PidFile -Value $proc.Id -NoNewline
    $deadline = (Get-Date).AddSeconds(20)
    while (((Get-Date) -lt $deadline) -and -not (Test-Path $ReadyFile)) { Start-Sleep -Milliseconds 150 }
    if (Test-Path $ReadyFile) { Write-Host "bridge started (pid $($proc.Id)), agent ready" }
    else { Write-Host "started (pid $($proc.Id)) but agent never signalled ready -- check grant/extension" }
  }
  "open"       { Send-Command "open" $Arg }
  "run"        { Send-Command "run"  $Arg -noWait:$NoWait }
  "ping"       { Send-Command "ping" "" }
  "screenshot" { Capture-To $Arg }
  "key"  { Send-Keys $Arg $DelayMs }          # single key or name (e.g. Escape)
  "keys" { Send-Keys $Arg $DelayMs }          # sequence, e.g. "Tab Tab Space Enter"
  "type" { Send-Type $Arg $DelayMs }          # literal text into the focused entry
  "stop" {
    $asePid = Get-AsePid
    Remove-Item $ReadyFile -ErrorAction SilentlyContinue
    if ($asePid) { Stop-Process -Id $asePid -Force -ErrorAction SilentlyContinue; Write-Host "stopped pid $asePid" }
    else { Write-Host "not running" }
    Remove-Item $PidFile -ErrorAction SilentlyContinue
  }
  default {
    Write-Host "usage: bridge.ps1 {start|open <file>|run <lua> [-NoWait]|screenshot <out>|key <Key>|keys <seq>|type <text>|ping|stop}"
  }
}
