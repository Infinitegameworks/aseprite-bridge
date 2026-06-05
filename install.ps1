# Install the Aseprite Bridge agent into your Aseprite extensions folder.
#
#   pwsh ./install.ps1            # copy-install (default; most robust)
#   pwsh ./install.ps1 -Symlink   # symlink to this repo (dev; needs Developer Mode/admin)
#
# Copy is the default because Aseprite keys its per-script filesystem grant on the
# loaded file's path -- a real file at the extensions path keeps that hash stable.
param([switch]$Symlink)
$ErrorActionPreference = "Stop"
$src = Join-Path $PSScriptRoot "extension"
$dst = Join-Path $env:APPDATA "Aseprite\extensions\aseprite-bridge"

if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
if ($Symlink) {
  try {
    New-Item -ItemType SymbolicLink -Path $dst -Target $src -ErrorAction Stop | Out-Null
    Write-Host "symlinked extension -> $dst"
  } catch {
    Copy-Item $src $dst -Recurse
    Write-Host "symlink failed (need Developer Mode/admin); copied instead -> $dst"
  }
} else {
  Copy-Item $src $dst -Recurse
  Write-Host "copied extension -> $dst"
}
Write-Host "Restart Aseprite if it is open, then:  pwsh ./bridge.ps1 start"
