import QtQuick
import Quickshell
import Quickshell.Io

// Headless singleton: probes the battery via sysfs (no privileges needed)
// and applies charge-limit changes through one explicit pkexec call each.
// Deliberately no state file — the limit itself lives in sysfs, and boot
// persistence lives in /etc/tmpfiles.d, so there is nothing to persist here.
Item {
  id: root

  property var shell: null
  property var settings: ({})

  readonly property string pluginId: "io.github.alexdont.battery-limiter"
  readonly property string tmpfilesPath: "/etc/tmpfiles.d/battery-limiter.conf"

  // Detected battery. supported = the kernel exposes an end threshold;
  // without it the plugin is read-only health stats (many laptops).
  property string batteryPath: ""
  property bool present: false
  property bool supported: false
  property int limit: 100
  property int capacity: -1
  property string status: ""
  property int cycleCount: -1
  property real full: -1
  property real fullDesign: -1
  // "Wh" when the kernel reports energy_* (µWh), "Ah" for charge_* (µAh).
  property string capacityUnit: "Wh"
  readonly property real healthPct: (full > 0 && fullDesign > 0) ? (full / fullDesign * 100) : -1

  property bool applying: false
  // One "reached the limit" notice per plug-in session; re-armed on unplug.
  property bool limitNotified: false
  property string lastLogDate: ""
  // Parsed daily log, oldest first: [{date, health, cycles}]
  property var healthHistory: []

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/" + pluginId
  readonly property string healthLog: stateDir + "/health-log.tsv"

  function refresh() { if (!probe.running) probe.running = true }

  // The battery path is rebuilt from the probe's own glob, but it still
  // crosses into a root shell — accept only a plain /sys battery dir.
  function validPath(p) {
    return /^\/sys\/class\/power_supply\/[A-Za-z0-9_][A-Za-z0-9_.:@-]*$/.test(p)
  }

  // One pkexec per change: writes the live sysfs value, then records it in
  // tmpfiles.d so systemd re-applies it at boot — or removes that file when
  // returning to 100 (stock behavior). Both values ride in as positional
  // parameters, never spliced into the shell string.
  function setLimit(pct) {
    pct = parseInt(pct, 10)
    if (isNaN(pct) || pct < 50 || pct > 100) return
    if (!root.supported || !root.validPath(root.batteryPath) || applyProc.running) return
    root.applying = true
    applyProc.pct = pct
    applyProc.command = ["pkexec", "sh", "-c",
      "set -e; " +
      "if [ -f \"$2/charge_control_start_threshold\" ]; then " +
      "  s=$(($1 - 5)); [ \"$s\" -lt 0 ] && s=0; " +
      "  if [ \"$1\" -lt 100 ]; then " +
      "    printf '%s\\n' \"$s\" > \"$2/charge_control_start_threshold\" 2>/dev/null || true; " +
      "    printf '%s\\n' \"$1\" > \"$2/charge_control_end_threshold\"; " +
      "  else " +
      "    printf '%s\\n' \"$1\" > \"$2/charge_control_end_threshold\"; " +
      "    printf '%s\\n' \"95\" > \"$2/charge_control_start_threshold\" 2>/dev/null || true; " +
      "  fi; " +
      "else " +
      "  printf '%s\\n' \"$1\" > \"$2/charge_control_end_threshold\"; " +
      "fi; " +
      "if [ \"$1\" -eq 100 ]; then rm -f \"$3\"; " +
      "else " +
      "  { if [ -f \"$2/charge_control_start_threshold\" ]; then " +
      "      s=$(($1 - 5)); [ \"$s\" -lt 0 ] && s=0; " +
      "      printf 'w %s/charge_control_start_threshold - - - - %s\\n' \"$2\" \"$s\"; " +
      "    fi; " +
      "    printf 'w %s/charge_control_end_threshold - - - - %s\\n' \"$2\" \"$1\"; " +
      "  } > \"$3\"; " +
      "fi",
      "sh", String(pct), root.batteryPath, root.tmpfilesPath]
    applyProc.running = true
  }

  function toggleOverlay() {
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", root.pluginId, "{}"])
  }

  function parseProbe(raw) {
    var path = "", vals = {}
    var lines = raw.split("\n")
    for (var j = 0; j < lines.length; j++) {
      var eq = lines[j].indexOf("=")
      if (eq <= 0) continue
      vals[lines[j].slice(0, eq)] = lines[j].slice(eq + 1).trim()
    }
    path = vals.path || ""
    if (!root.validPath(path)) {
      root.present = false
      root.supported = false
      root.batteryPath = ""
      return
    }
    var num = function(key) {
      var n = parseInt(vals[key], 10)
      return isNaN(n) ? -1 : n
    }
    root.batteryPath = path
    root.present = true
    root.supported = "limit" in vals
    if (num("limit") >= 1 && num("limit") <= 100) root.limit = num("limit")
    root.capacity = num("capacity")
    root.status = (vals.status || "").slice(0, 32)
    root.cycleCount = num("cycle_count")
    // energy_* are µWh, charge_* are µAh — health is a ratio, so either
    // pair works; energy wins when a laptop reports both.
    var energy = num("energy_full") > 0 && num("energy_full_design") > 0
    root.capacityUnit = energy ? "Wh" : "Ah"
    root.full = energy ? num("energy_full") : num("charge_full")
    root.fullDesign = energy ? num("energy_full_design") : num("charge_full_design")
    root.checkLimitReached()
    root.logHealth()
  }

  // The kernel parks the battery at the threshold ("Not charging" / "Full"
  // while plugged). Notify once when charge lands in a tight window around
  // the limit — a limit set far below the current charge stays quiet.
  function checkLimitReached() {
    if (root.status === "Discharging") { root.limitNotified = false; return }
    var reached = root.supported && root.limit < 100
      && root.capacity >= root.limit - 1 && root.capacity <= root.limit + 1
      && (root.status === "Not charging" || root.status === "Full")
    if (reached && !root.limitNotified) {
      root.limitNotified = true
      Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "low",
        "Battery Limiter", "Charged to the " + root.limit + "% limit — safe to unplug"])
    }
  }

  // One line per day feeding the card's History section: date, health %,
  // cycles, full, design, unit. ~41 bytes/day — a year of history is ~15 KB.
  //
  // Symlink-safe by construction: instead of ">>" (which follows a symlink
  // planted at our predictable path and would redirect the append into
  // another file), we build the next revision in a mktemp file — 0600, in
  // the same dir, owned by us — and mv it over the target. rename() replaces
  // a symlink at the destination rather than following it, so a planted
  // link is neutralized, not written through. Existing content is only
  // carried over when the current file is a real regular file (not a
  // symlink), which also keeps the once-a-day idempotency.
  function logHealth() {
    if (root.healthPct <= 0 || appendProc.running) return
    var today = new Date().toISOString().slice(0, 10)
    if (root.lastLogDate === today) return
    root.lastLogDate = today
    appendProc.command = ["sh", "-c",
      "d=\"${1%/*}\"; mkdir -p \"$d\" 2>/dev/null || exit 0; " +
      "{ [ -f \"$1\" ] && [ ! -L \"$1\" ] && tail -n 1 \"$1\" | grep -q \"^$2\"; } && exit 0; " +
      "tmp=$(mktemp \"$d/.health-XXXXXX\") || exit 0; " +
      "{ [ -f \"$1\" ] && [ ! -L \"$1\" ] && tail -n 400 \"$1\"; " +
      "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" \"$7\"; } > \"$tmp\" " +
      "&& mv -f \"$tmp\" \"$1\" || rm -f \"$tmp\"",
      "sh", root.healthLog, today, root.healthPct.toFixed(1),
      String(root.cycleCount), String(root.full), String(root.fullDesign), root.capacityUnit]
    appendProc.running = true
  }

  // The log is the plugin's own file, but it's re-validated like any other
  // input: bounded read, per-line format checks, capped entry count.
  function parseHistory(raw) {
    var out = []
    var lines = raw.split("\n")
    for (var j = 0; j < lines.length && out.length < 400; j++) {
      var p = lines[j].split("\t")
      if (p.length < 3 || !/^\d{4}-\d{2}-\d{2}$/.test(p[0])) continue
      var h = parseFloat(p[1])
      var c = parseInt(p[2], 10)
      if (!(h > 0 && h <= 200)) continue
      out.push({ date: p[0], health: h, cycles: isNaN(c) ? -1 : c })
    }
    root.healthHistory = out
  }

  Component.onCompleted: refresh()

  // Cheap poll so the bar stays honest if the limit is changed elsewhere
  // (tlp, a terminal, another session).
  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Process {
    id: probe
    // Prefer a battery with a charge limit; fall back to any battery that
    // can at least report health. head -c bounds the collector.
    command: ["sh", "-c",
      "{ b=''; for d in /sys/class/power_supply/*; do [ -f \"$d/charge_control_end_threshold\" ] && b=\"$d\" && break; done; " +
      "if [ -z \"$b\" ]; then for d in /sys/class/power_supply/*; do { [ -f \"$d/energy_full_design\" ] || [ -f \"$d/charge_full_design\" ]; } && b=\"$d\" && break; done; fi; " +
      "[ -z \"$b\" ] && exit 0; echo \"path=$b\"; " +
      "[ -f \"$b/charge_control_end_threshold\" ] && echo \"limit=$(cat \"$b/charge_control_end_threshold\")\"; " +
      "for k in capacity status cycle_count energy_full energy_full_design charge_full charge_full_design; do " +
      "[ -f \"$b/$k\" ] && echo \"$k=$(cat \"$b/$k\")\"; done; true; } | head -c 4096"]
    stdout: StdioCollector {
      onStreamFinished: root.parseProbe(text.slice(0, 4096))
    }
  }

  Process {
    id: appendProc
    onExited: function(code, status) { historyProc.running = true }
  }

  Process {
    id: historyProc
    // No-follow read: a symlink planted at our path must not make us read
    // and parse some other file. Only a real regular file is read.
    command: ["sh", "-c", "{ [ -f \"$1\" ] && [ ! -L \"$1\" ] && tail -n 400 \"$1\" || true; } | head -c 32768", "sh", root.healthLog]
    stdout: StdioCollector {
      onStreamFinished: root.parseHistory(text)
    }
  }

  Process {
    id: applyProc
    property int pct: 100
    onExited: function(code, status) {
      root.applying = false
      if (code === 0) {
        root.limitNotified = false
        root.refresh()
        Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "low",
          "Battery Limiter", applyProc.pct === 100
            ? "Charge limit removed — stock behavior restored"
            : "Charge limit set to " + applyProc.pct + "% (persists across reboots)"])
      } else if (code !== 126) {
        // 126 = the user dismissed the polkit dialog: their call, stay quiet.
        Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "critical",
          "Battery Limiter", "Could not set the charge limit (exit " + code + ")"])
      }
    }
  }

  // Bindable from Hyprland: omarchy-shell batterylimiter toggle
  // status() serves scripting (bar generators, conky-alikes) and debugging.
  IpcHandler {
    target: "batterylimiter"
    function toggle(): void { root.toggleOverlay() }
    function status(): string {
      return JSON.stringify({
        battery: root.batteryPath, present: root.present, supported: root.supported,
        limit: root.limit, capacity: root.capacity, state: root.status,
        healthPct: Math.round(root.healthPct * 10) / 10, cycles: root.cycleCount,
        historyDays: root.healthHistory.length, lastLogDate: root.lastLogDate
      })
    }
  }
}
