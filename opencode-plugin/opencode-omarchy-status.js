// opencode companion plugin for the folken.opencode-status Omarchy widget.
//
// Installation: copy (or symlink) this file into ~/.config/opencode/plugins/
// (see ../install.sh). No opencode.json changes needed for local-file plugins.
//
// What it does: subscribes to opencode's event bus and mirrors per-session
// activity into a small JSON state file that the Omarchy topbar widget reads.
// It also fires desktop notifications when opencode needs input or finishes.
//
// Notification model: toasts are uniform 5-second FYIs (low urgency,
// `-t 5000`). Severity lives in the bar icon (green pulse vs red blink),
// which persists as the backstop. Clicking a toast acknowledges that alert:
// the daemon runs bin/opencode-status-ack, which records the ack the widget
// reads. Closing a toast with X or letting it time out does NOT acknowledge;
// the icon keeps blinking until the session moves on.
//
// It NEVER focuses, raises, or otherwise touches any window.
//
// State file: $XDG_STATE_HOME/omarchy/opencode-status.json
//             (fallback: ~/.local/state/omarchy/opencode-status.json)
// {
//   "version": 1,
//   "updatedAt": 1735689600000,
//   "sessions": [
//     { "sessionId": "ses_...", "project": "my-app",
//       "state": "working|needs-input|done|error",
//       "detail": "permission: bash \"rm -rf /\"",
//       "updatedAt": 1735689600000,
//       "notifiedAt": 1735689600000 }
//   ]
// }
// Acks file: $XDG_STATE_HOME/omarchy/opencode-status-acks.json
// { "version": 1, "acks": [{ "summary": "Needs input · my-app", "at": ... }] }

const STATE_VERSION = 1;
const STALE_MS = 10 * 60 * 1000; // sessions untouched this long belong to dead processes
const FINISHED_TTL_MS = 120 * 1000; // keep done/error entries briefly, then drop them
const NOTIF_TIMEOUT_MS = 5000; // every toast hides after 5 seconds

// Built-in copy. The real source of truth is strings.json next to this file,
// optionally overridden by ~/.config/opencode/opencode-status-strings.json.
// Hardcoded fallback so a missing/corrupt file can never break the plugin.
const STRINGS_DEFAULTS = {
  needsInput: { title: "Needs input", body: "{time} — {detail}" },
  error: { title: "Error", body: "{time} — {detail}" },
  done: { title: "Done", body: "{time} — {project}" },
};

function stateDir() {
  const home = process.env.HOME || "";
  const base = process.env.XDG_STATE_HOME || (home + "/.local/state");
  return base + "/omarchy";
}

function stateFile() {
  return stateDir() + "/opencode-status.json";
}

// Summaries are per-project ("<Title> · <project>") so the widget, the
// ack script, and `omarchy notification dismiss` can address one alert
// precisely. Titles come from the strings file; the "·" suffix format is
// shared with BarWidget.qml summaryFor() — keep them in sync.
function summaryFor(title, project) {
  return title + " · " + project;
}

function fmtTime(when) {
  const d = when instanceof Date ? when : new Date();
  return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
}

// Function replacers: detail text may contain `$` sequences that a plain
// replacement string would reinterpret.
function render(tpl, vars) {
  return String(tpl)
    .replace("{time}", () => vars.time)
    .replace("{detail}", () => vars.detail)
    .replace("{project}", () => vars.project);
}

// Layered copy: hardcoded defaults <- bundled strings.json <- user override.
// Missing keys fall through each layer; corrupt files are skipped.
async function loadStrings(fs, bundledUrl, userPath) {
  const merged = JSON.parse(JSON.stringify(STRINGS_DEFAULTS));
  for (const src of [bundledUrl, userPath]) {
    try {
      const parsed = JSON.parse(await fs.readFile(src, "utf8"));
      if (!parsed || typeof parsed !== "object") continue;
      for (const key of Object.keys(merged)) {
        const layer = parsed[key];
        if (!layer || typeof layer !== "object") continue;
        if (typeof layer.title === "string" && layer.title !== "") merged[key].title = layer.title;
        if (typeof layer.body === "string" && layer.body !== "") merged[key].body = layer.body;
      }
    } catch {}
  }
  return merged;
}

function projectOf(directory) {
  if (!directory) return "opencode";
  const clean = String(directory).replace(/\/+$/, "");
  const parts = clean.split("/");
  return parts[parts.length - 1] || "opencode";
}

function sessionIdOf(properties) {
  if (!properties || typeof properties !== "object") return "default";
  for (const key of ["sessionID", "sessionId", "session_id", "id"]) {
    if (typeof properties[key] === "string" && properties[key] !== "") return properties[key];
  }
  if (properties.info && typeof properties.info.id === "string") return properties.info.id;
  return "default";
}

// session.status payloads vary across versions: a string, or an object
// carrying the status under some key. Returns "busy", "idle", or null.
function statusOf(properties) {
  if (!properties || typeof properties !== "object") return null;
  const candidates = [];
  if (typeof properties.status === "string") candidates.push(properties.status);
  for (const key of ["type", "state", "value"]) {
    if (typeof properties[key] === "string") candidates.push(properties[key]);
  }
  // nested one level (e.g. { status: { type: "busy" } })
  for (const value of Object.values(properties)) {
    if (value && typeof value === "object") {
      for (const key of ["type", "status", "state"]) {
        if (typeof value[key] === "string") candidates.push(value[key]);
      }
    }
  }
  const joined = candidates.join(" ").toLowerCase();
  if (joined.includes("idle")) return "idle";
  if (joined.includes("busy") || joined.includes("working")) return "busy";
  return null;
}

// Short human hint for *why* input is needed. Deliberately terse: this text
// lands in a notification body and a bar tooltip, never full prompts.
function detailOf(properties) {
  if (!properties || typeof properties !== "object") return "";
  const parts = [];
  for (const key of ["tool", "permission", "command", "question"]) {
    const v = properties[key];
    if (typeof v === "string" && v !== "") parts.push(key === "command" || key === "question" ? v : key + ": " + v);
  }
  if (parts.length === 0) return "";
  let detail = parts.join(" | ").replace(/\s+/g, " ");
  if (detail.length > 140) detail = detail.substring(0, 137) + "...";
  return detail;
}

async function readState(fs) {
  try {
    const raw = await fs.readFile(stateFile(), "utf8");
    const parsed = JSON.parse(raw);
    if (parsed && parsed.sessions instanceof Array) return parsed;
  } catch {}
  return { version: STATE_VERSION, updatedAt: 0, sessions: [] };
}

async function writeState(fs, path, sessions) {
  const payload = {
    version: STATE_VERSION,
    updatedAt: Date.now(),
    sessions,
  };
  const data = JSON.stringify(payload);
  await fs.mkdir(path.dirname(stateFile()), { recursive: true });
  // Atomic rename: the QML reader never sees a half-written file.
  const tmp = stateFile() + ".tmp-" + process.pid;
  await fs.writeFile(tmp, data, "utf8");
  await fs.rename(tmp, stateFile());
}

export const OmarchyStatus = async ({ directory }) => {
  let fs = null;
  let path = null;
  try {
    fs = await import("node:fs/promises");
    path = await import("node:path");
  } catch {
    return {}; // no fs access: stay inert rather than half-working
  }

  const project = projectOf(directory);

  // Absolute path to bin/opencode-status-ack (click-to-acknowledge target).
  // The plugin file itself is usually a symlink into the repo; resolve it.
  let ackBin = "";  try {
    const here = new URL(import.meta.url);
    const real = await fs.realpath(here);
    const root = path.dirname(path.dirname(real));
    const candidate = path.join(root, "bin", "opencode-status-ack");
    await fs.access(candidate);
    ackBin = candidate;
  } catch {}

  // Copy sources for loadStrings(): bundled file next to this plugin, plus
  // the optional user override. fs.readFile accepts URL objects, so the
  // symlinked install path needs no special handling here.
  const bundledStringsUrl = new URL("strings.json", import.meta.url);
  function userStringsPath() {
    return ((process.env.HOME || "") + "/.config/opencode/opencode-status-strings.json");
  }

  // Fire-and-forget desktop notification. Uniform 5-second low-urgency
  // toasts; severity is carried by the bar icon instead. Alert kinds carry
  // --exec so clicking the toast acknowledges it. Copy comes from the
  // strings file (re-read every time so edits apply immediately).
  // Never throws.
  async function notify(key, vars, clickable) {
    let strings = STRINGS_DEFAULTS;
    try {
      strings = await loadStrings(fs, bundledStringsUrl, userStringsPath());
    } catch {}
    const tpl = (strings && strings[key]) || STRINGS_DEFAULTS[key] || STRINGS_DEFAULTS.done;
    const summary = summaryFor(tpl.title, project);
    const body = render(tpl.body, {
      time: fmtTime(),
      detail: vars.detail || "",
      project,
    });
    try {
      const args = [
        "notification", "send",
        "--app-name", "opencode",
        "-u", "low",
        "-t", String(NOTIF_TIMEOUT_MS),
        summary,
      ];
      if (body) args.push(body);
      if (clickable && ackBin) args.push("--exec", ackBin, summary);
      const proc = Bun.spawn(["omarchy", ...args], { stdout: "ignore", stderr: "ignore" });
      if ((await proc.exited) === 0) return summary;
    } catch {}
    try {
      const args = ["-u", "low", "-t", String(NOTIF_TIMEOUT_MS), "opencode: " + summary];
      if (body) args.push(body);
      const proc = Bun.spawn(["notify-send", ...args], { stdout: "ignore", stderr: "ignore" });
      await proc.exited;
    } catch {}
    return summary;
  }

  // Dismiss our stale toast(s) for this project once the session moved on.
  // Best effort, silent; the notify-send fallback path has no dismiss.
  async function dismissStale() {
    let strings = STRINGS_DEFAULTS;
    try {
      strings = await loadStrings(fs, bundledStringsUrl, userStringsPath());
    } catch {}
    for (const key of ["needsInput", "error"]) {
      const title = (strings[key] && strings[key].title) || STRINGS_DEFAULTS[key].title;
      try {
        const proc = Bun.spawn(
          ["omarchy", "notification", "dismiss", summaryFor(title, project)],
          { stdout: "ignore", stderr: "ignore" }
        );
        await proc.exited;
      } catch {}
    }
  }

  // Re-read before every mutation: several opencode processes may share
  // the file. Last-writer-wins races are possible but self-heal on the
  // next event; nothing here is a counter, only state sets.
  async function mutate(sessionId, fn, create = true) {
    const now = Date.now();
    const current = await readState(fs);
    const sessions = [];
    for (const s of current.sessions) {
      if (!s || typeof s.sessionId !== "string") continue;
      const age = now - (typeof s.updatedAt === "number" ? s.updatedAt : 0);
      if (s.state === "done" || s.state === "error") {
        if (age > FINISHED_TTL_MS) continue;
      } else if (age > STALE_MS) {
        continue;
      }
      sessions.push(s);
    }
    let entry = sessions.find((s) => s.sessionId === sessionId);
    if (!entry) {
      // Tool-event heartbeats must never conjure sessions: their payloads
      // may not carry a session id at all.
      if (!create) return { changed: false, state: "" };
      entry = { sessionId, project, state: "working", detail: "", updatedAt: now, notifiedAt: 0 };
      sessions.push(entry);
    }
    const before = entry.state + "\n" + entry.detail;
    fn(entry, now);
    entry.updatedAt = now;
    const after = entry.state + "\n" + entry.detail;
    await writeState(fs, path, sessions);
    return { changed: before !== after, state: entry.state };
  }

  async function removeSession(sessionId) {
    try {
      const current = await readState(fs);
      const sessions = current.sessions.filter((s) => s && s.sessionId !== sessionId);
      if (sessions.length !== current.sessions.length) await writeState(fs, path, sessions);
    } catch {}
  }

  // Heartbeat for long tool runs: tool events are the only sign of life
  // during a lengthy execution, and the widget's stale guard would otherwise
  // hide the icon mid-work. Never notifies, never clears a pending input.
  async function heartbeat(sessionId) {
    try {
      await mutate(sessionId, (e) => {
        e.project = project;
        if (e.state !== "needs-input") {
          e.state = "working";
          e.detail = "";
        }
      }, false);
    } catch {}
  }

  return {
    event: async ({ event }) => {
      try {
        if (!event || typeof event.type !== "string") return;
        const props = event.properties || {};
        const sid = sessionIdOf(props);

        switch (event.type) {
          case "session.created": {
            await mutate(sid, (e) => {
              e.project = project;
              e.state = "working";
              e.detail = "";
            });
            break;
          }
          case "session.status": {
            const st = statusOf(props);
            if (st === "busy") {
              await heartbeat(sid);
            } else if (st === "idle") {
              const { changed, state } = await mutate(sid, (e, now) => {
                e.project = project;
                if (e.state === "working" || e.state === "needs-input") {
                  e.state = "done";
                  e.detail = "";
                  e.notifiedAt = now;
                }
              });
              if (changed && state === "done") {
                await dismissStale();
                await notify("done", { detail: "" }, false);
              }
            }
            break;
          }
          case "session.idle": {
            const { changed, state } = await mutate(sid, (e, now) => {
              e.project = project;
              if (e.state === "working" || e.state === "needs-input") {
                e.state = "done";
                e.detail = "";
                e.notifiedAt = now;
              }
            });
            // Guarded by the transition: a deprecated duplicate of
            // session.status/idle notifies at most once.
            if (changed && state === "done") {
              await dismissStale();
              await notify("done", { detail: "" }, false);
            }
            break;
          }
          case "session.error": {
            const { changed, state } = await mutate(sid, (e, now) => {
              e.project = project;
              if (e.state !== "error") {
                e.state = "error";
                e.detail = detailOf(props);
                e.notifiedAt = now;
              }
            });
            if (changed && state === "error") {
              await notify("error", { detail: detailOf(props) || project }, true);
            }
            break;
          }
          case "permission.asked": {
            const d = detailOf(props);
            const { changed } = await mutate(sid, (e, now) => {
              e.project = project;
              e.state = "needs-input";
              e.detail = d;
              e.notifiedAt = now;
            });
            // A repeat ask with identical detail is not a transition, so it
            // notifies at most once per distinct request. A *new* request
            // (changed detail) re-arms both toast and blink.
            if (changed) await notify("needsInput", { detail: d || project }, true);
            break;
          }
          case "permission.replied": {
            const { changed } = await mutate(sid, (e) => {
              if (e.state === "needs-input") {
                e.state = "working";
                e.detail = "";
              }
            });
            if (changed) await dismissStale();
            break;
          }
          case "session.deleted": {
            await removeSession(sid);
            break;
          }
          case "tool.execute.before":
          case "tool.execute.after": {
            await heartbeat(sid);
            break;
          }
          default:
            break;
        }
      } catch {
        // A status reporter must never break the session it observes.
      }
    },
  };
};
