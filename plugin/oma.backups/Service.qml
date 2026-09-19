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
  // One step at a time (see lib/progress.py): its name, whether it has a real
  // percentage or is just "working", and a details line (copied / speed / ETA).
  property string progressLabel: ""
  property bool progressBusy: false
  property string progressDetail: ""
  readonly property string progressText: progressBusy || progressLabel === ""
    ? (progressLabel || Model.phaseLabel(progressPhase))
    : progressLabel + "  " + progressPercent + "%"
  property string selectedDisk: ""
  property bool showAllDisks: false
  property bool wipeConfirmed: false
  property bool skipLoaded: false
  property bool backupIncomplete: false

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
  readonly property string seedSkip: {
    var r = detect && detect._root
    if (r) return r + "/lib/skip_defaults.py"
    return home + "/.local/share/oma-backups/lib/skip_defaults.py"
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
  // The current backup disk if it's plugged in, else any backup disk (the
  // same choice backup.sh makes via capsule_luks_partition).
  readonly property var capsule: {
    var d = detect && detect.disks ? detect.disks : []
    var want = detect ? detect.current_capsule_uuid : null
    var first = null
    for (var i = 0; i < d.length; i++) {
      var disk = d[i]
      if (disk.protected || disk.kind === "live-root" || disk.kind === "installer")
        continue
      if (disk.kind === "capsule" || disk.capsule) {
        if (want && disk.capsule && disk.capsule.luks_uuid === want) return disk
        if (!first) first = disk
      }
    }
    return first
  }
  // A paired Pi holding the backup USB (see remote.sh). It counts as the
  // backup disk whenever the USB isn't plugged in here, like backup.sh.
  property var remote: null
  readonly property bool remoteActive: remote !== null && capsule === null
  readonly property string remoteHost: remote ? String(remote.host || "") : ""
  readonly property bool hasCapsule: capsule !== null || remote !== null

  // Automatic backups: settings live in the user's schedule.json; the root
  // timer only exists once `schedule enable` has run.
  property var schedule: ({ enabled: false, every: "daily", retention: "smart" })
  property bool scheduleInstalled: false
  readonly property bool scheduleOn: schedule.enabled === true && scheduleInstalled
  readonly property string scheduleTool: {
    var r = detect && detect._root
    return (r || shareRoot) + "/lib/schedule.py"
  }

  // When the hourly check will next run a backup: due one interval after the
  // last successful one (a little early, like schedule.sh), at the first
  // top-of-the-hour check after that.
  property real lastSuccess: 0
  property real nowSec: Date.now() / 1000
  readonly property string nextBackupText: {
    if (!scheduleOn) return ""
    var interval = { hourly: 3600, daily: 86400, weekly: 604800 }[schedule.every] || 86400
    var due = Math.max(lastSuccess + interval - interval / 12, nowSec)
    // The timer fires on the hour in local time (not UTC: half-hour zones).
    var next = new Date(due * 1000)
    if (next.getMinutes() || next.getSeconds() || next.getMilliseconds()) {
      next.setMinutes(0, 0, 0)
      next.setHours(next.getHours() + 1)
    }
    var today = new Date(nowSec * 1000).toDateString() === next.toDateString()
    return "Next automatic backup around " + Qt.formatDateTime(next, today ? "HH:mm" : "ddd HH:mm")
  }

  function setSchedule(key, value) {
    scheduleProc.command = ["python3", root.scheduleTool, "set", key, String(value)]
    scheduleProc.running = true
  }

  function enableSchedule() {
    if (root.linked) setSchedule("enabled", "true")
    else privileged(["schedule", "enable"])
  }

  // Linked (see link.sh): everyday actions start systemd services that a
  // polkit rule lets this user run without a password. Otherwise they go
  // through sudo in a terminal, as before.
  property bool linked: false
  property real launchedAt: 0

  function linkLaptop() {
    privileged(["link"])
  }

  function startBackupService() {
    root.launchedAt = Date.now() / 1000
    startUnitProc.command = ["systemctl", "start", "--no-block", "oma-backups-backup.service"]
    startUnitProc.running = true
  }

  // Opening a restore point: oma-backups-browse@TS mounts it read-only and
  // writes /run/omarchy-backups-browse/TS.json when ready (or on error).
  property string browseTs: ""
  property string browsePhase: ""   // "", "opening", "open"
  property int browseWaited: 0
  property string browseMode: "open"  // "open" in Files, or "restore" (Restore my files)

  // After a "system + settings" restore: which restore point still has the
  // user's files (written by restore-to-disk.sh into their state folder).
  property string partialSnapshot: ""
  property bool restoringFiles: false
  property int restorePercent: 0

  function restoreMyFiles() {
    if (root.partialSnapshot === "" || !root.linked) return
    root.restoringFiles = true
    root.restorePercent = 0
    browse(root.partialSnapshot, "restore")
  }

  function stopRestoringFiles() {
    restoreProc.running = false
    root.restoringFiles = false
    closeBrowse()
  }

  function browse(ts, mode) {
    if (root.browseTs !== "" && root.browseTs !== ts) closeBrowse()
    root.browseMode = mode || "open"
    root.browseTs = ts
    root.browsePhase = "opening"
    root.browseWaited = 0
    root.lastError = ""
    browseStartProc.command = ["systemctl", "start", "oma-backups-browse@" + ts + ".service"]
    browseStartProc.running = true
    browsePoll.start()
    if (root.remoteActive)
      Quickshell.execDetached(["notify-send", "-a", "OmaBackups", "Opening " + Model.prettyStamp(ts),
        "From " + root.remoteHost + ". This can take a few seconds over the network."])
  }

  function closeBrowse() {
    if (root.browseTs === "") return
    Quickshell.execDetached(["systemctl", "stop", "oma-backups-browse@" + root.browseTs + ".service"])
    browsePoll.stop()
    root.browseTs = ""
    root.browsePhase = ""
  }
  readonly property bool backupMounted: detect && detect.backup_mounted === true
  readonly property var capsuleDisk: (detect && detect.capsule_disk) || null
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

  function hasSkip(path) {
    for (var i = 0; i < skipListModel.count; i++) {
      if (skipListModel.get(i).path === path) return true
    }
    return false
  }

  function privileged(args) {
    // Always a visible terminal: sudo/pkexec's own auth prompt (password
    // or fingerprint) happens before our code even runs, so a hidden
    // pkexec route can't show progress for it either way — the terminal
    // is the one place that prompt is actually visible.
    var cmd = ["omarchy-launch-floating-terminal-with-presentation", "sudo", root.cli].concat(args)
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
    // Also catches pairing/unpairing: the file may not exist to be watched.
    remoteFile.reload()
    scheduleFile.reload()
    timerFile.reload()
    linkedFile.reload()
    lastSuccessFile.reload()
    if (!root.restoringFiles) partialFile.reload()
    nowSec = Date.now() / 1000
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
      var sizeText = (s && s.size_total !== undefined && s.size_total !== null)
        ? Model.formatSize(s.size_total) : ""
      snapList.append({ whenText: title, snapId: stamp, sizeText: sizeText })
    }
  }

  onBackupRunningChanged: if (!backupRunning) Qt.callLater(refreshSnapshots)

  function loadSkipFile() {
    loadSkipProc.command = ["python3", root.seedSkip]
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
    if (root.linked)
      Quickshell.execDetached(["systemctl", "stop", "oma-backups-backup.service", "oma-backups-scheduled.service"])
    else
      privileged(["stop"])
  }

  function openSnapshot(ts) {
    if (!ts) return
    if (root.linked) { browse(ts); return }
    if (root.remoteActive) return
    Quickshell.execDetached([root.cli, "open", ts])
  }

  function pairRemote(host) {
    var h = String(host || "").trim()
    if (!h) return
    privileged(["remote", "pair", h])
  }

  function forgetRemote() {
    privileged(["remote", "forget"])
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
        if (!cap && root.remote === null) {
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
      var fresh = typeof j.at === "number" && root.launchedAt > 0 && j.at >= root.launchedAt - 2
      if (root.launchedBackup && !root.sawBackupStatus && !fresh) {
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
    if (typeof j.incomplete === "boolean") root.backupIncomplete = j.incomplete
    if (typeof j.percent === "number" || (j.percent && String(j.percent).length))
      root.progressPercent = parseInt(j.percent, 10) || 0
    root.progressEta = j.eta || ""
    root.progressSpeed = j.speed || ""
    if (j.phase) root.progressPhase = j.phase
    root.progressLabel = j.label ? String(j.label) : ""
    root.progressBusy = j.busy === true
    root.progressDetail = j.detail ? String(j.detail) : ""
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
        if (root.linked) root.startBackupService()
        else root.privileged(["backup", "--yes"])
      }
    }
  }

  Process {
    id: startUnitProc
    onExited: function (code) {
      if (code === 0) return
      root.backupRunning = false
      root.launchedBackup = false
      root.lastError = "Couldn't start the backup. Try Settings → link this laptop again."
    }
  }

  Process {
    id: browseStartProc
    onExited: function (code) {
      if (code !== 0 && root.browsePhase === "opening") {
        root.lastError = "Couldn't open that restore point."
        browsePoll.stop()
        root.browseTs = ""
        root.browsePhase = ""
      }
    }
  }

  property string _browseOut: ""
  Process {
    id: browseReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._browseOut = String(text || "")
    }
    onExited: {
      if (root.browsePhase !== "opening" || root._browseOut === "") return
      var j
      try { j = JSON.parse(root._browseOut) } catch (e) { return }
      if (j.state === "ready" && j.path) {
        browsePoll.stop()
        root.browsePhase = "open"
        if (root.browseMode === "restore") {
          // Only what's missing: never overwrite anything changed since.
          restoreProc.command = ["rsync", "-a", "--ignore-existing", "--info=progress2",
            String(j.path) + "/", root.home + "/"]
          restoreProc.running = true
        } else {
          Quickshell.execDetached(["xdg-open", String(j.path)])
        }
      } else if (j.state === "error") {
        root.lastError = String(j.message || "Couldn't open that restore point.")
        root.restoringFiles = false
        root.closeBrowse()
      }
    }
  }

  Process {
    id: restoreProc
    stdout: SplitParser {
      splitMarker: "\r"
      onRead: function (line) {
        var m = /\s(\d{1,3})%\s/.exec(line)
        if (m) root.restorePercent = parseInt(m[1], 10)
      }
    }
    onExited: function (code) {
      var wasRestoring = root.restoringFiles
      root.restoringFiles = false
      root.closeBrowse()
      if (!wasRestoring) return
      if (code === 0) {
        // Everything's back: the protected restore point can be thinned again.
        Quickshell.execDetached(["rm", "-f", root.home + "/.local/state/omarchy-backups/partial-restore.json"])
        root.partialSnapshot = ""
        Quickshell.execDetached(["notify-send", "-a", "OmaBackups", "Your files are back",
          "Everything from the backup has been restored to your home folder."])
      } else {
        root.lastError = "Restoring your files stopped before finishing. Press Restore my files to carry on."
      }
    }
  }

  FileView {
    id: partialFile
    path: root.home + "/.local/state/omarchy-backups/partial-restore.json"
    printErrors: false
    onLoaded: {
      try {
        var j = JSON.parse(text())
        root.partialSnapshot = /^\d{8}T\d{6}Z$/.test(j.snapshot || "") ? j.snapshot : ""
      } catch (e) {
        root.partialSnapshot = ""
      }
    }
    onLoadFailed: root.partialSnapshot = ""
  }

  Timer {
    id: browsePoll
    interval: 500
    repeat: true
    onTriggered: {
      root.browseWaited += 1
      if (root.browseWaited > 120) {
        root.lastError = "Opening that restore point timed out."
        root.closeBrowse()
        return
      }
      if (browseReadProc.running) return
      root._browseOut = ""
      browseReadProc.command = ["cat", "/run/omarchy-backups-browse/" + root.browseTs + ".json"]
      browseReadProc.running = true
    }
  }

  FileView {
    id: lastSuccessFile
    path: root.home + "/.local/state/omarchy-backups/last-success"
    printErrors: false
    onLoaded: {
      var v = parseInt(String(text()).trim(), 10)
      root.lastSuccess = isNaN(v) ? 0 : v
    }
    onLoadFailed: root.lastSuccess = 0
  }

  FileView {
    id: linkedFile
    path: "/etc/omarchy-backups/linked.json"
    printErrors: false
    onLoaded: root.linked = true
    onLoadFailed: root.linked = false
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

  Process {
    id: scheduleProc
    onExited: scheduleFile.reload()
  }

  FileView {
    id: scheduleFile
    path: root.home + "/.config/omarchy-backups/schedule.json"
    printErrors: false
    onLoaded: {
      try {
        var j = JSON.parse(text())
        root.schedule = {
          enabled: j.enabled === true,
          every: ["hourly", "daily", "weekly"].indexOf(j.every) >= 0 ? j.every : "daily",
          retention: j.retention === "keep" ? "keep" : "smart"
        }
      } catch (e) {}
    }
  }

  FileView {
    id: timerFile
    path: "/etc/systemd/system/oma-backups-scheduled.timer"
    printErrors: false
    onLoaded: root.scheduleInstalled = true
    onLoadFailed: root.scheduleInstalled = false
  }

  FileView {
    id: remoteFile
    path: "/etc/omarchy-backups/remote.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var j = JSON.parse(text())
        root.remote = (j && j.host) ? j : null
      } catch (e) {
        root.remote = null
      }
    }
    onLoadFailed: root.remote = null
    onFileChanged: reload()
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
