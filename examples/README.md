# Examples

Runnable end-to-end examples. Install the agent first (`pwsh ../install.ps1`) and
point the bridge at your Aseprite binary via `$env:ASEPRITE_EXE` (or edit the
default in `../bridge.ps1`).

| Script | What it shows |
|---|---|
| `capture-dialog.ps1` | Screenshot an Aseprite dialog headlessly (the headline use case). |
| `capture-sprite.ps1` | Open a sprite, run Lua against it, and screenshot the window. |

Generated `*.png` outputs are gitignored.
