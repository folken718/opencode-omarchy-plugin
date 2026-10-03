# Quickstart — opencode-status on a fresh Omarchy Quattro machine

Get the topbar opencode indicator running in about two minutes.
Two parts: the **bar widget** (icon) and the **opencode reporter** (events).

## 1. Add the widget

```bash
omarchy plugin add https://github.com/folken718/opencode-omarchy-plugin.git --enable
```

This clones the repo into `~/.config/omarchy/plugins/folken.opencode-status/`
and enables it. The icon lands in the bar's default section; move it anywhere:

```bash
omarchy bar move folken.opencode-status --section center
```

(Or drag it with the mouse — grab any widget and drop it where you want it.)

## 2. Install the opencode reporter

```bash
cd ~/.config/omarchy/plugins/folken.opencode-status
./install.sh
```

`install.sh` does three things:

1. Symlinks the event plugin into `~/.config/opencode/plugins/` (global, so
   every project reports — no `opencode.json` edits needed).
2. Seeds the state file the widget reads.
3. Asks where the icon should live: `left`, `center`, or `right`
   (default `center`). Non-interactive alternative:
   `BAR_SECTION=left ./install.sh`.

Then **restart opencode** — plugins load at startup, so a running session
won't pick it up until relaunch.

## 3. Verify (30 seconds)

1. In any project, run opencode with something that asks permission, e.g.
   make sure a `bash` rule is set to `ask` and run a shell command.
2. You should see:
   - a **green pulsing** line-art mark in the topbar while it works,
   - a **red blinking** mark plus a 5-second toast (`Needs input · <project>`
     with timestamp) when it asks,
   - hover the icon for the per-session list,
   - **click the toast** to acknowledge (stops the blink for that alert).
3. When the session finishes: a `Done` toast, brief flash, icon hides.

No opencode activity → no icon. That is the design (hidden when idle).

## Customize (optional)

```bash
# Icon colors, applied live, no restart:
omarchy bar set folken.opencode-status colorWorking "#00ff00"
omarchy bar set folken.opencode-status colorWaiting "#ff0000"
omarchy bar set folken.opencode-status colorFlash "#ffffff"
```

Notification wording lives in `opencode-plugin/strings.json`
(`{time}`, `{detail}`, `{project}` placeholders). Copy it to
`~/.config/opencode/opencode-status-strings.json` to override without
touching the repo — partial files are fine, edits apply to the next toast.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Icon never appears | Restart opencode (plugin loads at startup). Check `~/.local/state/omarchy/opencode-status.json` exists after running a task. |
| Icon stuck on | Delete the state file; entries older than 10 min are ignored automatically (dead-process guard). |
| Widget not listed | `omarchy-shell shell rescanPlugins`, then `omarchy plugin list \| grep opencode`. |
| Changed files, bar unchanged | `omarchy-shell shell rescanPlugins`; if still stale, `omarchy restart shell` (clears in-memory component caches). |
| Toasts don't show | `omarchy notification send --app-name opencode -u low -t 5000 "test"` — if that works, check opencode loaded the plugin (restart it). |

## Uninstall

```bash
omarchy plugin remove folken.opencode-status
rm ~/.config/opencode/plugins/opencode-omarchy-status.js
rm -f ~/.local/state/omarchy/opencode-status.json \
      ~/.local/state/omarchy/opencode-status-acks.json
```
