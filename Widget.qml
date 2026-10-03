import QtQuick
import Quickshell
import Quickshell.Io
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// (Pixel mark geometry lives inline in iconComponent below: file-scope
// `component` declarations are not parsed by this shell's QML engine.)

// opencode status indicator. Visible only while at least one opencode session
// is active and unacknowledged. The companion opencode plugin
// (opencode-plugin/) owns the state file; this widget only reads it (plus
// the ack file it shares with the ack script). It never focuses, raises, or
// otherwise touches any window.
BarWidget {
  id: root
  moduleName: "folken.opencode-status"

  // Aggregate over all fresh, unacknowledged sessions in the state file:
  // idle | working | needs-input | done | error
  property string aggregateState: "idle"
  property var sessions: []
  property var acked: []
  property string stateFilePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/opencode-status.json"
  property string acksFilePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/opencode-status-acks.json"

  readonly property bool needsInput: aggregateState === "needs-input"
  readonly property bool busy: aggregateState === "working"
  readonly property bool flashing: aggregateState === "done" || aggregateState === "error"
  // Blink phase for the needs-input red alternation below.
  property bool blinkPhase: true
  onNeedsInputChanged: if (needsInput) blinkPhase = true

  // Icon palette, user-customizable via the manifest schema
  // (omarchy bar set folken.opencode-status colorWorking "#00ff00").
  // Invalid values fall back silently; empty colorFlash follows the theme.
  function validColor(value, fallback) {
    var s = String(value === undefined || value === null ? "" : value)
    if (/^#[0-9a-fA-F]{6}$/.test(s) || /^#[0-9a-fA-F]{3}$/.test(s)) return s
    return fallback
  }
  readonly property color workingColor: root.validColor(root.setting("colorWorking", "#4ade80"), "#4ade80")
  readonly property color waitingColor: root.validColor(root.setting("colorWaiting", "#ef5350"), "#ef5350")
  readonly property color flashColor: root.setting("colorFlash", "") === ""
    ? button.foreground
    : root.validColor(root.setting("colorFlash", ""), button.foreground)

  // Freshness: a session the writer hasn't touched in a while belongs to a
  // dead opencode process. Never trust it, never blink forever on it.
  readonly property real staleAfterMs: 10 * 60 * 1000
  readonly property real flashLingerMs: 8000
  readonly property int maxTooltipRows: 6

  visible: aggregateState !== "idle"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function severity(state) {
    if (state === "needs-input") return 3
    if (state === "working") return 2
    if (state === "error" || state === "done") return 1
    return 0
  }

  // Notification titles, shared with opencode-plugin/strings.json (plus the
  // optional user override). The widget must build the same summaries the
  // writer sends, or ack matching breaks. Hardcoded English is the last
  // fallback so a missing file can never break matching.
  property var strings: ({ needsInput: "Needs input", error: "Error", done: "Done" })

  function readTitles(file) {
    var raw = ""
    try {
      raw = file.text() || ""
    } catch (e) {
      return null
    }
    if (!raw) return null
    try {
      var parsed = JSON.parse(raw)
      return (parsed && typeof parsed === "object") ? parsed : null
    } catch (e) {
      return null
    }
  }

  function refreshStrings() {
    var merged = { needsInput: "Needs input", error: "Error", done: "Done" }
    var layers = [readTitles(bundledStringsFile), readTitles(userStringsFile)]
    for (var i = 0; i < layers.length; i++) {
      var layer = layers[i]
      if (!layer) continue
      for (var key in merged) {
        if (layer[key] && typeof layer[key].title === "string" && layer[key].title !== "")
          merged[key] = layer[key].title
      }
    }
    strings = merged
    root.refresh()
  }

  function titleFor(key) {
    var t = root.strings[key]
    return (typeof t === "string" && t !== "") ? t : key
  }

  // Notification summary the writer uses for an alert session. Shared format
  // with the writer and the ack script: "<Title> · <project>", titles from
  // the strings file above.
  function summaryFor(state, project) {
    if (state === "needs-input") return root.titleFor("needsInput") + " · " + project
    if (state === "error") return root.titleFor("error") + " · " + project
    return ""
  }

  // An alert is discarded once an ack for its summary arrives that is at
  // least as new as the notification that raised it. Newer notifications
  // (new notifiedAt) re-arm the alert automatically.
  function isAcked(session) {
    var summary = root.summaryFor(session.state, session.project)
    if (summary === "") return false
    var notifiedAt = typeof session.notifiedAt === "number" ? session.notifiedAt : 0
    for (var i = 0; i < root.acked.length; i++) {
      var a = root.acked[i]
      if (a && a.summary === summary && typeof a.at === "number" && a.at >= notifiedAt) return true
    }
    return false
  }

  function goIdle() {
    aggregateState = "idle"
    sessions = []
    lingerTimer.stop()
  }

  function refresh() {
    var raw = ""
    try {
      raw = stateFile.text() || ""
    } catch (e) {
      root.goIdle()
      return
    }
    if (!raw) {
      root.goIdle()
      return
    }
    var parsed = null
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      return // corrupt mid-write (non-atomic reader); keep last good state
    }
    if (!parsed || !(parsed.sessions instanceof Array)) {
      root.goIdle()
      return
    }
    var now = Date.now()
    var fresh = []
    for (var i = 0; i < parsed.sessions.length; i++) {
      var s = parsed.sessions[i]
      if (!s || typeof s.sessionId !== "string") continue
      if (typeof s.updatedAt !== "number" || (now - s.updatedAt) > root.staleAfterMs) continue
      fresh.push({
        sessionId: String(s.sessionId),
        project: typeof s.project === "string" && s.project !== "" ? s.project : "opencode",
        state: typeof s.state === "string" ? s.state : "working",
        detail: typeof s.detail === "string" ? s.detail : "",
        notifiedAt: typeof s.notifiedAt === "number" ? s.notifiedAt : 0
      })
    }
    // Flag acknowledgements (needs a second pass: isAcked reads root.acked).
    for (var k = 0; k < fresh.length; k++) {
      fresh[k].acknowledged = root.isAcked(fresh[k])
    }
    // Most severe first: the icon and the tooltip lead with what needs you.
    // Acknowledged alerts sort as idle: discarded from the icon, still
    // listed in the tooltip.
    fresh.sort(function(a, b) {
      var sa = a.acknowledged ? 0 : severity(a.state)
      var sb = b.acknowledged ? 0 : severity(b.state)
      return sb - sa
    })
    var top = "idle"
    if (fresh.length > 0 && !fresh[0].acknowledged) {
      top = fresh[0].state
      if (top !== "needs-input" && top !== "working" && top !== "done" && top !== "error") top = "working"
    }
    if (top === "idle") {
      // Either nothing fresh, or everything left was acknowledged.
      if (fresh.length === 0) {
        root.goIdle()
        return
      }
      sessions = fresh
      aggregateState = "idle"
      lingerTimer.stop()
      return
    }
    var changed = (top !== root.aggregateState)
    sessions = fresh
    aggregateState = top
    // No pulseAnim/blinkTimer restarts here: their `running` bindings own
    // them (imperative restarts would silently break those bindings), and
    // animation endpoints re-read each loop iteration.
    if (changed) {
      if (root.flashing) lingerTimer.restart()
      else lingerTimer.stop()
    }
  }

  function refreshAcks() {
    var raw = ""
    try {
      raw = acksFile.text() || ""
    } catch (e) {
      return
    }
    if (!raw) return
    try {
      var parsed = JSON.parse(raw)
      if (parsed && parsed.acks instanceof Array) {
        acked = parsed.acks
        root.refresh()
      }
    } catch (e) {
      return
    }
  }

  function shortDetail(detail) {
    if (!detail) return ""
    var oneLine = String(detail).replace(/\s+/g, " ")
    if (oneLine.length > 90) return oneLine.substring(0, 87) + "..."
    return oneLine
  }

  function buildTooltip() {
    if (root.sessions.length === 0) return "opencode"
    var waiting = 0
    var active = 0
    var snoozed = 0
    for (var i = 0; i < root.sessions.length; i++) {
      var st = root.sessions[i]
      if (st.acknowledged) snoozed++
      else if (st.state === "needs-input") waiting++
      else if (st.state === "working") active++
    }
    var header = "opencode"
    if (waiting > 0) header += waiting === 1 ? " - 1 needs input" : " - " + waiting + " need input"
    else if (active > 0) header += active === 1 ? " - working" : " - " + active + " working"
    else if (snoozed > 0) header += " - acknowledged"
    else header += " - " + root.aggregateState
    var lines = [header]
    var shown = Math.min(root.sessions.length, root.maxTooltipRows)
    for (var j = 0; j < shown; j++) {
      var s = root.sessions[j]
      var mark = (s.state === "needs-input" && !s.acknowledged) ? "\u25CF" : "\u25CB"
      var row = mark + " " + s.project + " - " + s.state
      if (s.acknowledged) row += " (acknowledged)"
      var d = root.shortDetail(s.detail)
      if (d !== "") row += " (" + d + ")"
      lines.push(row)
    }
    if (root.sessions.length > shown) lines.push("... and " + (root.sessions.length - shown) + " more")
    return lines.join("\n")
  }

  FileView {
    id: bundledStringsFile
    path: Qt.resolvedUrl("opencode-plugin/strings.json").toString().replace(/^file:\/\//, "")
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshStrings()
    onLoaded: root.refreshStrings()
  }

  FileView {
    id: userStringsFile
    path: (Quickshell.env("HOME") + "/.config/opencode/opencode-status-strings.json")
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshStrings()
    onLoaded: root.refreshStrings()
    onLoadFailed: root.refreshStrings()
  }

  FileView {
    id: stateFile
    path: root.stateFilePath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
    onLoaded: root.refresh()
    onLoadFailed: root.goIdle()
  }

  FileView {
    id: acksFile
    path: root.acksFilePath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshAcks()
    onLoaded: root.refreshAcks()
  }

  // The watcher is instant when it fires; the poll is the backstop for
  // atomic-rename writes and anything the watcher misses. reload() forces
  // fresh bytes (text() alone can serve a stale snapshot when the watcher
  // misses rapid successive writes); the resulting onLoaded runs refresh().
  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      stateFile.reload()
      acksFile.reload()
      bundledStringsFile.reload()
      userStringsFile.reload()
    }
  }

  // done/error are announcements, not ongoing states: linger, then hide.
  // The (5-second) notification itself is the persistent record.
  Timer {
    id: lingerTimer
    interval: root.flashLingerMs
    onTriggered: if (root.flashing) root.goIdle()
  }

  // Green pulse while working, fast red blink while input is needed. Shallow
  // fades only: the white outline below stays at full brightness throughout.
  SequentialAnimation {
    id: pulseAnim
    running: root.needsInput || root.busy
    loops: Animation.Infinite
    NumberAnimation {
      target: root
      property: "opacity"
      to: root.needsInput ? 0.85 : 0.7
      duration: root.needsInput ? 400 : 1200
      easing.type: Easing.InOutQuad
    }
    NumberAnimation {
      target: root
      property: "opacity"
      to: 1.0
      duration: root.needsInput ? 400 : 1200
      easing.type: Easing.InOutQuad
    }
    onRunningChanged: if (!running) root.opacity = 1
  }

  Timer {
    id: blinkTimer
    interval: 400
    running: root.needsInput
    repeat: true
    onRunningChanged: if (running) root.blinkPhase = true
    onTriggered: root.blinkPhase = !root.blinkPhase
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.needsInput
    tooltipText: root.buildTooltip()
    iconComponent: Component {
      Item {
        id: markRoot
        width: 16
        height: 16
        anchors.centerIn: parent
        // Every line takes the state color: green while working, blinking
        // red while input is needed, flash color for done/error.
        property color lineColor: root.needsInput
          ? (root.blinkPhase ? Color.urgent : root.waitingColor)
          : (root.busy ? root.workingColor : root.flashColor)
        Behavior on lineColor { ColorAnimation { duration: 160 } }
        // Badge: rounded-square stroke, transparent interior.
        Shape {
          width: 16
          height: 16
          antialiasing: true
          ShapePath {
            strokeColor: markRoot.lineColor
            strokeWidth: 2
            fillColor: "transparent"
            PathSvg { path: "M5,1 H11 Q15,1 15,5 V11 Q15,15 11,15 H5 Q1,15 1,11 V5 Q1,1 5,1 Z" } // TEMPMARKER square-test
          }
        }
        // Ring: 2px bars.
        Rectangle { x: 3; y: 3; width: 10; height: 2; color: markRoot.lineColor }
        Rectangle { x: 3; y: 11; width: 10; height: 2; color: markRoot.lineColor }
        Rectangle { x: 3; y: 3; width: 2; height: 10; color: markRoot.lineColor }
        Rectangle { x: 11; y: 3; width: 2; height: 10; color: markRoot.lineColor }
        // Inner block as outline: 1px bars on the counter's bottom half.
        Rectangle { x: 5; y: 8; width: 6; height: 1; color: markRoot.lineColor }
        Rectangle { x: 5; y: 10; width: 6; height: 1; color: markRoot.lineColor }
        Rectangle { x: 5; y: 8; width: 1; height: 3; color: markRoot.lineColor }
        Rectangle { x: 10; y: 8; width: 1; height: 3; color: markRoot.lineColor }
      }
    }
    // Clicking never focuses anything. It only dismisses a transient
    // done/error flash early; working/needs-input clear on their own when
    // the session moves on (or via notification acknowledge).
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton && root.flashing) root.goIdle()
      else root.refresh()
    }
  }
}
