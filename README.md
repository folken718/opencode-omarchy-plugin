# opencode-status for Omarchy

An Omarchy topbar icon that appears **only while opencode is working** — plus a
desktop notification when opencode needs your input or finishes.

- **Icon hidden when idle.** No pixels spent when nothing is running.
- **Green pulse** while working, **fast red blink** while input is needed, both
  on a constant **white outline** so the mark reads on any theme.
  `needs-input` is sticky: it keeps blinking until you reply, so a missed
  notification never strands an agent.
- **Hover the icon** to see every active session, with the ones waiting for
  input on top.
- **Never steals focus.** No window is ever raised or focused — not
  automatically, not on click. Toasts auto-hide after 5 seconds.
- **Click a toast to acknowledge** that alert: the icon stops blinking for it
  (tooltip keeps it listed as acknowledged) until something new happens.
  Closing a toast with X or letting it time out does *not* acknowledge — the
  blink persists as the backstop.

## Install

```bash
# 1. The widget (from this repo)
omarchy plugin add https://github.com/folken718/opencode-omarchy-plugin.git --enable

# 2. The opencode reporter (local files) — asks where to place the icon
./install.sh
# non-interactive: BAR_SECTION=left ./install.sh
# then restart opencode so it loads the new plugin
```

`install.sh` symlinks `opencode-plugin/opencode-omarchy-status.js` into
`~/.config/opencode/plugins/` (global, so every project reports), seeds the
state file, and asks which topbar section should hold the icon
(left/center/right, default center). To re-place later without reinstalling:

```bash
omarchy bar move folken.opencode-status --section left
```

## How it works

```
opencode event bus → opencode-omarchy-status.js → state file → Widget.qml
   session.created/status/idle/error          ~/.local/state/omarchy/
   permission.asked/replied                   opencode-status.json
```

The JS plugin is a standard opencode plugin (`event` hook). It maintains a
per-session map in the state file and notifies via
`omarchy notification send` (falls back to `notify-send`).
Summaries are per-project (`Needs input · my-app`) so toasts, acks, and
dismissals address one alert precisely. `notifiedAt` marks when an alert was
raised; an ack only silences alerts at least as old, so newer requests
re-arm automatically. Tool events act as a heartbeat so long runs don't trip
the widget's stale guard; they never notify and never clear a pending input.

| opencode event | widget | notification (5s, low urgency) |
|---|---|---|
| `session.created`, busy `session.status`, tool activity | ● green pulse | — |
| `permission.asked` | ● red blink (sticky) | `Needs input · <project>` (click = acknowledge) |
| `permission.replied` | back to pulse, stale toast dismissed | — |
| `session.idle` | brief “done” flash, then hide, stale toast dismissed | `Done · <project>` |
| `session.error` | brief “error” flash, then hide | `Error · <project>` (click = acknowledge) |

Notify-once semantics: notifications fire only on state *transitions*, so the
deprecated `session.idle` duplicate of `session.status` can't double-notify.
Concurrent opencode processes share one file; writes are atomic renames and
every handler re-reads before mutating, so races self-heal on the next event.
Sessions untouched for 10 minutes are treated as dead processes and ignored.

## Renaming

The manifest id is `folken.opencode-status`. Forks should rename it to
`<your-user>.opencode-status` (folder name, `manifest.json` `id`, and
`moduleName` in `Widget.qml` must all match) so ids stay collision-free.

## Validate / troubleshoot

```bash
omarchy plugin validate ./opencode-omarchy-plugin
omarchy plugin list | grep -i opencode
```

- Icon never appears: check the state file exists and opencode loaded the
  plugin (restart opencode after `./install.sh`).
- Stuck icon: the writer may have died; entries older than 10 minutes are
  ignored automatically, or delete the state file to reset.

## Notification copy (`strings.json`)

Toast text lives in `opencode-plugin/strings.json` — titles and body
templates with `{time}` (local `HH:MM`), `{detail}`, and `{project}`
placeholders:

```json
{
  "needsInput": { "title": "Needs input", "body": "{time} — {detail}" },
  "done":       { "title": "Done",        "body": "{time} — {project}" }
}
```

- The summary line is always `<title> · <project>` (type first, then project).
  That `·` suffix format is load-bearing (ack matching, tooltip, dismiss), so
  only `title`/`body` are customizable.
- To override without touching the repo, copy the file to
  `~/.config/opencode/opencode-status-strings.json` — partial files are fine,
  missing keys fall back to the bundled file, then to built-ins. Edits apply
  to the next toast; no restart needed. The widget reads the same files, so
  renamed titles keep working with acks automatically.

## Icon colors

The line-art mark takes its color from three widget settings (invalid values
fall back silently):

| Setting | Default | Used for |
|---|---|---|
| `colorWorking` | `#4ade80` | lines while opencode is working |
| `colorWaiting` | `#ef5350` | blink line color while input is needed |
| `colorFlash` | _(empty)_ | done/error flash; empty follows the theme foreground |

Change them live — no restart, the widget rebinds on the spot:

```bash
omarchy bar set folken.opencode-status colorWorking "#00ff00"
omarchy bar set folken.opencode-status colorWaiting "#ff0000"
omarchy bar set folken.opencode-status colorFlash "#ffffff"
```

The settings panel (Setup menu → bar widget settings) renders the same three
fields from the manifest schema.

## Dependencies & privileges

- **Runtime:** the Omarchy Quattro shell (`omarchy-shell`); no second Quickshell
  process is ever started. The widget only reads two JSON files.
- **Notifications:** `omarchy notification send`, falling back to `notify-send`.
  Both are fire-and-forget; failures never affect the session.
- **opencode side:** a single local-file plugin
  (`opencode-plugin/opencode-omarchy-status.js`, Bun runtime, `node:fs` only —
  zero npm dependencies).
- **Privileges:** everything runs as your user. No sudo, no setuid, no network,
  no sandbox escapes. The plugin folder contains no symlinks (per shell rules;
  the dev symlink lives one level up, at `~/.config/omarchy/plugins/`).
- **Brand mark:** drawn in-code as snapped rectangles (no asset files),
  modeled on the official opencode favicon's pixel "o" (© SST / opencode
  project) with a bolder ring for bar-size legibility.

## Notes

- **Entry point is `Widget.qml`, not `BarWidget.qml`.** The development guide
  uses `BarWidget.qml`, but in this shell that name (as well as
  `StatusWidget.qml` / `Main.qml`) fails to load with `File name case
  mismatch`, while `Widget.qml` with byte-identical content loads reliably
  across rescans. The validator only requires the manifest mapping to match
  the file on disk, so this deviation is compliance-safe.

## Attribution

The bar mark is a hand-drawn pixel-grid reinterpretation of the official
opencode favicon ([opencode.ai/favicon.svg](https://opencode.ai/favicon.svg)):
same "o"-with-filled-lower-block concept, bolder ring for 12px legibility.
Mark concept © the SST / opencode project.
