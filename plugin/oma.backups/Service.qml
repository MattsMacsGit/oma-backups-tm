import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var detect: ({})
  property var snapshots: []
  ListModel {
    id: snapList
    dynamicRoles: true
  }
  readonly property var snapModel: snapList
  property string statusLine: "idle"
  property string lastError: ""
  property bool refreshing: false
  property bool backupRunning: false
  property bool launchedBackup: false
  property bool sawBackupStatus: false
  property int progressPercent: 0
  property string progressEta: ""
  property string progressSpeed: ""
  property string progressPhase: ""
  property string selectedDisk: ""
  property bool showAllDisks: false
  property bool wipeConfirmed: false
  property bool showTerminal: true
  property bool skipLoaded: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string cli: home + "/.local/bin/oma-backups"
  readonly property string shareRoot: home + "/.local/share/oma-backups"
  readonly property string listSnaps: shareRoot + "/lib/list_snapshots.py"
  readonly property string skipFile: home + "/.config/omarchy-backups/skip-paths.txt"
  readonly property string picker: {
    var r = detect && detect._root
    if (r) return r + "/lib/pick_path.py"
    return home + "/.local/share/oma-backups/lib/pick_path.py"
  }
  readonly property string writeSkip: {
    var r = detect && detect._root
    if (r) return r + "/lib/write_skip_paths.py"
    return home + "/.local/share/oma-backups/lib/write_skip_paths.py"
  }

  readonly property var disks: {
    var d = detect && detect.disks ? detect.disks : []
    var out = []
    for (var i = 0; i < d.length; i++) {
      var disk = d[i]
      if (disk.protected) continue
      if (!root.showAllDisks && disk.hidden_by_default) continue
      out.push(disk)
    }
    return out
  }
  readonly property var capsule: {
    var d = detect && detect.disks ? detect.disks : []
    for (var i = 0; i < d.length; i++) {
      var disk = d[i]
      if (disk.protected || disk.kind === "live-root" || disk.kind === "installer")
        continue
      if (disk.kind === "capsule" || disk.capsule) return disk
    }
    return null
  }
  readonly property bool hasCapsule: capsule !== null
  readonly property bool backupMounted: detect && detect.backup_mounted === true
  readonly property string selectedDiskLabel: {
    var d = disks
    for (var i = 0; i < d.length; i++) {
      if (d[i].path === selectedDisk) return Model.diskLabel(d[i])
    }
    return selectedDisk
  }
  property bool replaceDisk: false
  readonly property int snapshotCount: snapList.count
  readonly property string lastSnapshot: snapList.count > 0 ? snapList.get(0).whenText : ""

  property string _detectOut: ""
  ListModel { id: skipListModel }
  readonly property var skipModel: skipListModel
  readonly property int skipCount: skipListModel.count

  function privileged(args) {
    var cmd
    if (root.showTerminal) {
      cmd = ["omarchy-launch-floating-terminal-with-presentation", "sudo", root.cli].concat(args)
    } else {
      cmd = ["pkexec", "/usr/lib/oma-backups/pkexec-wrapper.sh"].concat(args)
    }
    Quickshell.execDetached(cmd)
  }

  function refresh() {
    refreshing = true
    if (!detectProc.running) {
      _detectOut = ""
      detectProc.command = [root.cli, "detect", "--json"]
      detectProc.running = true
    }
    if (!statusProc.running) statusProc.running = true
    refreshSnapshots()
    if (!skipLoaded) loadSkipFile()
  }

  function refreshSnapshots() {
    if (snapProc.running) return
    snapProc.command = [root.cli, "snapshots"]
    snapProc.running = true
  }

  function applySnapshots(raw) {
    if (!root.hasCapsule) {
      root.snapshots = []
      snapList.clear()
      return
    }
    var rows = Model.parseSnapshots(raw)
    root.snapshots = rows
    snapList.clear()
    for (var i = 0; i < rows.length; i++) {
      var s = rows[i]
      var stamp = String((s && s.timestamp) || "")
      var title = String((s && s.label) || "")
      if (!title || /^\d{8}T\d{6}Z$/.test(title)) title = Model.prettyStamp(stamp)
      if (!title) title = stamp
      snapList.append({ whenText: title, snapId: stamp })
    }
  }

  onBackupRunningChanged: if (!backupRunning) Qt.callLater(refreshSnapshots)

  function loadSkipFile() {
    loadSkipProc.command = ["bash", "-lc", "mkdir -p \"$HOME/.config/omarchy-backups\"; cat \"$HOME/.config/omarchy-backups/skip-paths.txt\" 2>/dev/null || true"]
    loadSkipProc.running = true
  }

  function persistSkipPaths() {
    var args = ["python3", root.writeSkip]
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
  property bool pendingStop: false

  function compileThen(kind) {
    persistSkipPaths()
    if (kind === "first") {
      pendingFirstRunDisk = selectedDisk
      pendingBackup = false
      pendingStop = false
    } else if (kind === "backup") {
      pendingFirstRunDisk = ""
      pendingBackup = true
      pendingStop = false
    }
    compileProc.command = [root.cli, "compile-excludes"]
    compileProc.running = true
  }

  function startFirstRun(disk) {
    if (!disk) {
      lastError = "Pick a disk first"
      return
    }
    if (!wipeConfirmed) {
      lastError = "Confirm that this will erase the disk"
      return
    }
    var live = detect && detect.live_root_disk
    if (live && disk === live) {
      lastError = "That is the disk this computer is running from. Plug in the backup USB."
      return
    }
    selectedDisk = disk
    compileThen("first")
  }

  function startBackup() {
    compileThen("backup")
  }

  function stopBackup() {
    pendingStop = true
    pendingBackup = false
    pendingFirstRunDisk = ""
    launchedBackup = false
    sawBackupStatus = false
    backupRunning = false
    privileged(["stop"])
  }

  function openSnapshot(ts) {
    if (!ts) return
    Quickshell.execDetached([root.cli, "open", ts])
  }

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
      try {
        var parsed = JSON.parse(root._detectOut)
        parsed._root = root.home + "/.local/share/oma-backups"
        root.detect = parsed
        var cap = false
        var disks = parsed.disks || []
        for (var i = 0; i < disks.length; i++) {
          if (disks[i].kind === "capsule" && !disks[i].protected) cap = true
        }
        if (!cap) {
          root.snapshots = []
          snapList.clear()
        }
        if (!root.backupRunning) root.lastError = ""
      } catch (e) {
        root.lastError = "Could not list disks"
      }
      root.refreshing = false
    }
  }

  property string _snapOut: ""
  Process {
    id: snapProc
    command: [root.cli, "snapshots"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root._snapOut = String(text || "")
        root.applySnapshots(root._snapOut)
      }
    }
    onExited: function (code) {
      if (code !== 0 && root.hasCapsule && root.snapshots.length === 0)
        root.lastError = "Could not read restore points from the backup disk"
    }
  }

  function applyStatusText(raw) {
    raw = String(raw || "").trim()
    if (!raw) return
    var j
    try { j = JSON.parse(raw) } catch (e) { return }
    if (!j || typeof j !== "object") return
    if (j.phase === "error") {
      // If we just launched this attempt and haven't seen it report
      // running yet, an "error" here is leftover from a *previous*,
      // unrelated failure that hasn't been overwritten on disk yet (e.g.
      // the sudo/fingerprint-auth window before backup.sh writes its own
      // first status) — not a failure of this attempt. Ignore it rather
      // than tearing down state we just set.
      if (root.launchedBackup && !root.sawBackupStatus) {
        // stale leftover — ignore
      } else {
        root.backupRunning = false
        root.launchedBackup = false
        root.sawBackupStatus = false
        if (j.line) root.lastError = String(j.line)
      }
    } else if (j.stale === true) {
      if (root.launchedBackup && j.phase !== "error") root.backupRunning = true
      else if (typeof j.running === "boolean") root.backupRunning = false
    } else if (j.running === true) {
      root.backupRunning = true
      root.sawBackupStatus = true
    } else if (root.launchedBackup) {
      if (j.phase === "done" || j.phase === "idle") {
        root.backupRunning = false
        root.launchedBackup = false
        root.sawBackupStatus = false
      } else {
        root.backupRunning = true
      }
    } else if (typeof j.running === "boolean") {
      root.backupRunning = j.running
    }
    if (typeof j.percent === "number" || (j.percent && String(j.percent).length))
      root.progressPercent = parseInt(j.percent, 10) || 0
    root.progressEta = j.eta || ""
    root.progressSpeed = j.speed || ""
    if (j.phase) root.progressPhase = j.phase
    var rp = parseInt(j.rsync_percent, 10)
    if (!isNaN(rp)) root.statusLine = Model.phaseLabel(j.phase) + "  " + rp + "%"
    else if (j.phase) root.statusLine = Model.phaseLabel(j.phase) + "  " + root.progressPercent + "%"
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
    command: [root.cli, "status"]
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
        var disk = root.pendingFirstRunDisk
        root.pendingFirstRunDisk = ""
        root.lastError = ""
        root.backupRunning = true
        root.launchedBackup = true
        root.sawBackupStatus = false
        root.privileged(["first-run", disk])
      } else if (root.pendingBackup) {
        root.pendingBackup = false
        root.lastError = ""
        root.backupRunning = true
        root.launchedBackup = true
        root.sawBackupStatus = false
        root.privileged(["backup", "--yes"])
      }
    }
  }

  Timer {
    interval: 500
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statusProc.running) statusProc.running = true
  }
  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  FileView {
    id: snapFile
    path: (Quickshell.env("HOME") || "") + "/.local/state/omarchy-backups/snapshots.txt"
    watchChanges: true
    printErrors: false
    onLoaded: if (root.hasCapsule) root.applySnapshots(text())
    onFileChanged: reload()
  }
}
