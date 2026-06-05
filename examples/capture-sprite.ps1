# Example: open a sprite in a live Aseprite GUI and screenshot the window.
#
#   $env:ASEPRITE_EXE = "C:\path\to\aseprite.exe"
#   pwsh ./examples/capture-sprite.ps1 -File C:/art/hero.aseprite
param([Parameter(Mandatory)][string]$File)
$bridge = Join-Path $PSScriptRoot "..\bridge.ps1"
$out = Join-Path $PSScriptRoot "sprite.png"

& $bridge start
& $bridge open $File
& $bridge run "return 'layers=' .. #app.activeSprite.layers"
& $bridge screenshot $out
& $bridge stop
Write-Host "saved $out"
