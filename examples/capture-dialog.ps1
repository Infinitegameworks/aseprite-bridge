# Example: screenshot an Aseprite dialog headlessly -- the thing batch mode and
# focus-stealing prevention make impossible.
#
#   $env:ASEPRITE_EXE = "C:\path\to\aseprite.exe"   # or rely on bridge.ps1's default
#   pwsh ./examples/capture-dialog.ps1
#
# Shows a dialog non-blocking (show{wait=false}), captures it, then quits. For a
# truly MODAL dialog (show{} / show{wait=true}), use `bridge.ps1 run -NoWait ...`
# then `bridge.ps1 key Escape` -- see the README.
$bridge = Join-Path $PSScriptRoot "..\bridge.ps1"
$out = Join-Path $PSScriptRoot "dialog.png"

& $bridge start
$lua = "local d = Dialog('Aseprite Bridge'); " +
       "d:label{ text='Captured headlessly.' }; " +
       "d:entry{ label='Name:', text='hero' }; " +
       "d:button{ text='OK' }; d:button{ text='Cancel' }; " +
       "d:show{ wait=false }"
& $bridge run $lua
Start-Sleep -Milliseconds 400
& $bridge screenshot $out
& $bridge stop
Write-Host "saved $out"
