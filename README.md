# Aseprite Bridge

Drive a **live Aseprite GUI** from the shell — open files, run Lua,
**screenshot modal dialogs**, and **drive those dialogs with the keyboard** —
without the OS fighting you over window focus.

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

Runnable end-to-end scripts live in [`examples/`](examples/) (`capture-dialog.ps1`,
`capture-sprite.ps1`).

### Driving a dialog with the keyboard

You can also *interact* with a dialog, not just screenshot it. Synthetic
keystrokes are delivered with **`PostMessage`** straight to the window handle, so
— like `PrintWindow` — they land **without stealing foreground**. Aseprite's UI
(laf) navigates by keyboard: `Tab` moves focus, `Space` toggles a checkbox,
`Enter` activates the focused/default button, `Esc` cancels, and typing fills the
focused entry.

```powershell
# open a modal that sets a global when its OK button fires
pwsh ./bridge.ps1 run -NoWait "_G.OK=false; local d=Dialog('x'); d:entry{id='name',focus=true}; d:button{id='ok',text='OK',onclick=function() _G.OK=true; d:close() end}; d:show{wait=true}"
pwsh ./bridge.ps1 type "hero"          # fill the focused entry
pwsh ./bridge.ps1 keys "Tab Enter"     # Tab to OK, then activate it
pwsh ./bridge.ps1 run  "return tostring(_G.OK)"   # -> "true": the dialog committed
```

The first widget already has focus when a dialog opens — don't add a leading
`Tab`. Tune the inter-key pace with `-DelayMs` (default 60). See
[limitations](#notes--caveats) for what keyboard input can and can't reach.

## Commands

| Command | Description |
|---|---|
| `start` | Grant + launch a persistent GUI instance and wait for the agent. |
| `open <file>` | Open a sprite file. |
| `run <lua> [-NoWait]` | Run a Lua chunk in Aseprite. Returns its value; `-NoWait` for modal-opening code. |
| `screenshot <out.png>` | Capture the Aseprite window (including any open dialog) via `PrintWindow`. |
| `key <Key>` | Send one key — a named key (`Tab`, `Enter`, `Space`, `Esc`, `Up`…`F12`) or a single character. |
| `keys "<seq>"` | Send a space-separated sequence, e.g. `"Tab Tab Space Enter"`. |
| `type "<text>"` | Type literal text into the focused entry. |
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
 bridge.ps1  ──PostMessage──▶  Aseprite window               # for key/keys/type (native, no agent)
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

### Keyboard input limitations

`key`/`keys`/`type` deliver `WM_KEYDOWN`/`WM_KEYUP` via `PostMessage`, which laf
turns into key events **without foreground**. But `PostMessage` cannot modify the
target process's keyboard state, so a few things are out of reach:

- **No modifiers.** `Shift`/`Ctrl`/`Alt` combos (and therefore **uppercase
  letters and shifted symbols**) don't register — laf reads modifier state from
  the keyboard-state table, which only real hardware / `SendInput` updates. `type`
  warns when it sees a character that needs Shift; it still sends the unshifted
  key. Text arrives lowercase.
- **Combobox dropdowns.** A combobox's open dropdown is a separate popup that
  doesn't take arrow keys through the main window handle, so you can't reliably
  pick an option by keyboard. Same goes for **mouse-only canvas widgets** (e.g.
  `dialog_utils.scrollableList`). These need real coordinate clicks.
- **First widget is pre-focused** on open — start interacting immediately; a
  leading `Tab` skips past it.
- Delivery requires the window to be **un-minimized**; the bridge restores it
  (without activating) before sending keys or capturing.

Everything else a native dialog needs — entry text (lowercase/digits), `Tab`
navigation, `Space` to toggle checks, `Enter` to activate buttons, `Esc` to
cancel — works headlessly. Full-fidelity input (modifiers, uppercase) would mean
`SendInput`, which requires bringing the window to the foreground.

## License

MIT — see [LICENSE](LICENSE).
