import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var detect: ({})
  property var snapshots: []
  property string statusLine: "idle"
  property string lastError: ""
  property bool refreshing: false
  property bool backupRunning: false
  property int progressPercent: 0
  property string progressEta: ""
  property string progressSpeed: ""
  property string progressPhase: ""
  property string selectedDisk: ""
  readonly property string cli: (Quickshell.env("HOME") || "/home/test") + "/Work/omarchy-tm/omarchy-backups"
  readonly property string skipFile: (Quickshell.env("HOME") || "/home/test") + "/.config/omarchy-backups/skip-paths.txt"

  readonly property var disks: {
    var d = detect && detect.disks ? detect.disks : []
    var out = []
    for (var i = 0; i < d.length; i++) {
      if (!d[i].protected) out.push(d[i])
    }
    return out
  }
  readonly property var capsule: {
    var d = detect && detect.disks ? detect.disks : []
    for (var i = 0; i < d.length; i++) {
      if (d[i].capsule) return d[i]
    }
    return null
  }
  readonly property bool hasCapsule: capsule !== null
  readonly property string lastSnapshot: snapshots.length ? snapshots[snapshots.length - 1].timestamp : ""

  property string _detectOut: ""
  property bool skipLoaded: false

  ListModel { id: skipListModel }
  readonly property var skipModel: skipListModel

  function refresh() {
    if (detectProc.running) return
    refreshing = true
    lastError = ""
    _detectOut = ""
    detectProc.running = true
    statusProc.running = true
    snapProc.running = true
    if (!skipLoaded) loadSkipFile()
  }

  function loadSkipFile() {
    loadSkipProc.command = ["bash", "-lc", "mkdir -p \"$HOME/.config/omarchy-backups\"; cat \"$HOME/.config/omarchy-backups/skip-paths.txt\" 2>/dev/null || true"]
    loadSkipProc.running = true
  }

  function persistSkipPaths() {
    var args = ["python3", (Quickshell.env("HOME") || "/home/test") + "/Work/omarchy-tm/lib/write_skip_paths.py"]
    for (var i = 0; i < skipListModel.count; i++) args.push(skipListModel.get(i).path)
    persistProc.command = args
    persistProc.running = true
  }

  function addSkip(path) {
    if (!path) return
    var p = String(path).replace(/\/+$/, "")
    if (p.indexOf("file://") === 0) p = decodeURIComponent(p.slice(7))
    for (var i = 0; i < skipListModel.count; i++) {
      if (skipListModel.get(i).path === p) return
    }
    Qt.callLater(function () {
      skipListModel.append({ path: p })
      persistSkipPaths()
    })
  }

  function removeSkip(path) {
    var target = path
    Qt.callLater(function () {
      for (var i = skipListModel.count - 1; i >= 0; i--) {
        if (skipListModel.get(i).path === target) skipListModel.remove(i)
      }
      persistSkipPaths()
    })
  }

  property string pendingFirstRunDisk: ""
  property bool pendingBackup: false

  function compileExcludes() {
    persistSkipPaths()
    compileProc.command = [root.cli, "compile-excludes"]
    compileProc.running = true
  }

  function startFirstRun(disk) {
    if (!disk) {
      lastError = "Pick a disk first"
      return
    }
    selectedDisk = disk
    pendingFirstRunDisk = disk
    pendingBackup = false
    compileExcludes()
  }

  function startBackup() {
    pendingFirstRunDisk = ""
    pendingBackup = true
    compileExcludes()
  }

  function openSnapshot(ts) {
    if (!ts) return
    var base = "/run/omarchy-backups/home/" + ts
    var userHome = (Quickshell.env("USER") || "test")
    Quickshell.execDetached(["xdg-open", base + "/" + userHome])
  }

  readonly property string picker: (Quickshell.env("HOME") || "/home/test") + "/Work/omarchy-tm/lib/pick_path.py"
  function pickFolder() { pickProc.command = ["python3", root.picker]; pickProc.running = true }
  function pickFile() { pickProc.command = ["python3", root.picker, "--file"]; pickProc.running = true }

  property string _pickOut: ""
  Process {
    id: pickProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._pickOut = String(text || "").trim()
    }
    onExited: function (code) {
      if (code === 0 && root._pickOut !== "") root.addSkip(root._pickOut)
    }
  }

  Process {
    id: detectProc
    command: [root.cli, "detect", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._detectOut = String(text || "")
    }
    onExited: function () {
      try { root.detect = JSON.parse(root._detectOut) } catch (e) { root.lastError = "detect failed" }
      root.refreshing = false
    }
  }

  Process {
    id: snapProc
    command: [root.cli, "snapshots"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var out = []
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim()
          if (line.indexOf("VALID") === 0) {
            var parts = line.split(/\s+/)
            out.push({ timestamp: parts[1] || line, raw: line })
          }
        }
        root.snapshots = out
      }
    }
  }

  function applyStatusText(raw) {
    raw = String(raw || "").trim()
    if (!raw) return
    try {
      var j = JSON.parse(raw)
    } catch (e) {
      return
    }
    if (!j || typeof j !== "object") return
    if (typeof j.running === "boolean") root.backupRunning = j.running
    root.progressPercent = parseInt(j.percent, 10) || 0
    root.progressEta = j.eta || ""
    root.progressSpeed = j.speed || ""
    root.progressPhase = j.phase || ""
    root.statusLine = j.line || (j.phase || "")
  }

  FileView {
    id: statusFile
    path: "/run/omarchy-backups.status"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyStatusText(text())
    onFileChanged: reload()
  }

  Process {
    id: statusProc
    command: ["cat", "/run/omarchy-backups.status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatusText(text)
    }
  }

  Process {
    id: loadSkipProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        skipListModel.clear()
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim()
          if (line && line.indexOf("#") !== 0) skipListModel.append({ path: line })
        }
        root.skipLoaded = true
      }
    }
  }

  Process { id: persistProc }
  Process {
    id: compileProc
    onExited: function (code) {
      if (code !== 0) {
        root.lastError = "Could not build skip list"
        return
      }
      if (root.pendingFirstRunDisk !== "") {
        Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
          "sudo", root.cli, "first-run", root.pendingFirstRunDisk])
        root.pendingFirstRunDisk = ""
        root.backupRunning = true
      } else if (root.pendingBackup) {
        Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
          "sudo", root.cli, "backup", "--yes"])
        root.pendingBackup = false
        root.backupRunning = true
      }
    }
  }

  Timer {
    interval: 400
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statusProc.running) statusProc.running = true
  }
  Timer {
    interval: 8000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
