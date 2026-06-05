# Aseprite Bridge

Drive a **live Aseprite GUI** from the shell — open files, run Lua, and
**screenshot modal dialogs** — without the OS fighting you over window focus.

Aseprite's `--script` works great in batch (`-b`) mode, but batch has no window,
so you can't screenshot the UI. And launching a GUI Aseprite from a background
process can't reliably bring its window (or a modal dialog) to the foreground —
Windows blocks focus-stealing, so a naive screenshot grabs whatever was already
on top. The bridge solves this by:

- keeping a **persistent GUI instance** alive with a small companion extension
  (the *agent*) that executes commands off a file queue, and
- capturing with **`PrintWindow`**, which renders a window to a bitmap even when
  it's unfocused or behind others — no foreground required.

Aseprite draws its dialogs *inside* the main window, so a single capture grabs
whatever modal is open. That's the whole point: you can finally screenshot a
dialog headlessly.

> Windows + PowerShell 7 only (uses Win32 `PrintWindow` / `System.Drawing`).

## Install

```powershell
git clone https://github.com/Infinitegameworks/aseprite-bridge
cd aseprite-bridge
pwsh ./install.ps1            # copies the agent into your Aseprite extensions folder
```

Point the bridge at your Aseprite binary with the `ASEPRITE_EXE` env var, or pass
`-Aseprite <path>` (defaults to a local dev build path otherwise).

## Usage

```powershell
pwsh ./bridge.ps1 start                       # launch a persistent GUI + agent
pwsh ./bridge.ps1 open  C:/art/hero.aseprite  # open a sprite
pwsh ./bridge.ps1 run   "return #app.activeSprite.layers"   # run Lua, get its return value
pwsh ./bridge.ps1 screenshot shot.png         # capture the window (dialogs included)
pwsh ./bridge.ps1 stop                        # quit
```

### Screenshotting a modal dialog

A modal `Dialog:show()` blocks the agent, so run it **`-NoWait`**, capture, then
dismiss:

```powershell
pwsh ./bridge.ps1 run -NoWait "Dialog('Hi'):label{text='hello'}:button{text='OK'}:show()"
pwsh ./bridge.ps1 screenshot dialog.png
pwsh ./bridge.ps1 key Escape          # or: pwsh ./bridge.ps1 stop
```

## Commands

| Command | Description |
|---|---|
| `start` | Grant + launch a persistent GUI instance and wait for the agent. |
| `open <file>` | Open a sprite file. |
| `run <lua> [-NoWait]` | Run a Lua chunk in Aseprite. Returns its value; `-NoWait` for modal-opening code. |
| `screenshot <out.png>` | Capture the Aseprite window (including any open dialog) via `PrintWindow`. |
| `key <Key>` | Send a keystroke (`SendKeys` syntax, e.g. `Escape`, `Enter`). |
| `ping` | Check the agent is alive. |
| `stop` | Quit the instance. |

## How it works

```
 bridge.ps1  ──writes──▶  %USERPROFILE%/.aseprite-bridge/cmd/<seq>.cmd
   (CLI)                                  │
                                          ▼  (agent Timer polls every 150ms)
 extension/bridge.lua  ──executes──▶  open / run / ping
   (in the live GUI)                      │
                                          ▼
 bridge.ps1  ◀──reads───  .aseprite-bridge/res/<seq>.res     # for open/run/ping
 bridge.ps1  ──PrintWindow──▶  out.png                       # for screenshot (native, no agent)
```

- **Protocol** is plain files: `cmd/<seq>.cmd` (op + arg) → `res/<seq>.res`
  (`OK`/`ERR` + output), written via temp-and-rename so readers never see a
  partial file.
- **Inert by default.** The agent only does anything when launched with
  `ASEPRITE_BRIDGE=1` (which `start` sets), so it never touches the filesystem in
  your normal Aseprite sessions.
- **Script security.** Aseprite prompts before a script may write files. `start`
  pre-grants the agent full trust by writing `SHA1(<extension path>) = 31` into
  `aseprite.ini [script_access]` — the same grant the "Give full trust" button
  would create, done non-interactively.

## Files

| Path | Role |
|---|---|
| `bridge.ps1` | The shell CLI (queueing, native capture, lifecycle). |
| `extension/bridge.lua` | The in-Aseprite agent (Timer poll loop). |
| `extension/package.json` | Aseprite extension manifest. |
| `install.ps1` | Installs the agent into the Aseprite extensions folder. |

## Notes & caveats

- Prefer `bridge.ps1 stop` over force-killing Aseprite. Force-killing a GUI
  instance with an unsaved document can leave crash-recovery state behind — don't
  open real assets in throwaway sessions; use disposable sprites for tests.
- `PrintWindow` returns the window's own render. On Aseprite's Skia surface it
  works (use the included `PW_RENDERFULLCONTENT` flag); other GPU-composited apps
  may differ.
- The grant hash keys on the extension's **absolute path**, so re-run
  `install.ps1` (not `-Symlink`) if you move the repo, then `start` re-grants.

## License

MIT — see [LICENSE](LICENSE).
