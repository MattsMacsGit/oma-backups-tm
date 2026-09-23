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
  // The last failed backup's message from the status file. Kept separately
  // so the disk-list refresh doesn't blank it and make the panel jump.
  property string backupError: ""
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
  // The second bar: the whole backup, weighted by how much data each step has
  // to move (see lib/progress.py), plus what it thinks is left.
  property int overallPercent: 0
  property int overallStep: 0
  property int overallSteps: 0
  property string overallEta: ""
  property string overallTotalTime: ""
  property string elapsedText: ""
  readonly property bool hasOverall: overallSteps > 0
  readonly property string overallText: {
    if (!hasOverall) return ""
    var s = "Overall  ·  " + overallPercent + "%"
    if (overallStep > 0) s += "  ·  step " + overallStep + " of " + overallSteps
    return s
  }
  readonly property string overallDetail: {
    if (overallEta === "") return elapsedText !== "" ? elapsedText + " so far" : ""
    var s = "about " + overallEta + " left"
    if (overallTotalTime !== "") s += " of about " + overallTotalTime
    return s
  }
  readonly property string progressText: progressBusy || progressLabel === ""
    ? (progressLabel || Model.phaseLabel(progressPhase))
    : progressLabel + "  " + progressPercent + "%"
  property string selectedDisk: ""
  property bool showAllDisks: false
  property bool wipeConfirmed: false
  property bool skipLoaded: false
  property bool restoreSkipLoaded: false
  property int _leftOutAtFinish: 0
  property bool backupIncomplete: false
  // Set by the Panel: the disk scan only needs to run while someone is looking.
  property bool panelOpen: false

  // Read from the VERSION file rather than written out by hand in the Panel:
  // it was the pair of copies most easily forgotten at release time.
  property string version: ""

  readonly property string home: Quickshell.env("HOME") || ""
  // Where this plugin finds OmaBackups itself. install.sh leaves links in the
  // home folder (~/.local/bin/oma-backups -> ~/.local/share/oma-backups ->
  // wherever the repo was cloned), and on a quick-restored system that clone
  // is a visible folder that came back empty — so every one of those links
  // dangles and each call through them fails with nothing in the log. That is
  // what killed "Restore my files"' terminal. link.sh's root copy lives in the
  // system area, always comes back with it, and is what the services already
  // run; prefer it, and keep the home links for an install never linked.
  property bool hasRootCopy: false
  readonly property string shareRoot: hasRootCopy
    ? "/usr/local/lib/oma-backups"
    : home + "/.local/share/oma-backups"
  readonly property string cli: shareRoot + "/omarchy-backups"
  readonly property string listSnaps: shareRoot + "/lib/list_snapshots.py"
  readonly property string skipFile: home + "/.config/omarchy-backups/skip-paths.txt"
  readonly property string picker: {
    var r = detect && detect._root
    if (r) return r + "/lib/pick_path.py"
    return shareRoot + "/lib/pick_path.py"
  }
  readonly property string writeSkip: {
    var r = detect && detect._root
    if (r) return r + "/lib/write_skip_paths.py"
    return shareRoot + "/lib/write_skip_paths.py"
  }
  readonly property string keptPointsCli: {
    var r = detect && detect._root
    if (r) return r + "/lib/kept_points.py"
    return shareRoot + "/lib/kept_points.py"
  }
  readonly property string writeRestoreSkip: {
    var r = detect && detect._root
    if (r) return r + "/lib/write_restore_skips.py"
    return shareRoot + "/lib/write_restore_skips.py"
  }
  readonly property string seedSkip: {
    var r = detect && detect._root
    if (r) return r + "/lib/skip_defaults.py"
    return shareRoot + "/lib/skip_defaults.py"
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
    // Same margin as schedule.sh: a twelfth of the interval, never under
    // 10 minutes, so this note and the actual check agree.
    var grace = Math.max(interval / 12, 600)
    var due = Math.max(lastSuccess + interval - grace, nowSec)
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

  function startBackupService(force) {
    root.launchedAt = Date.now() / 1000
    // A systemd unit takes no arguments, so a forced backup leaves a note in
    // the state folder and backup.sh picks it up and deletes it. $1 keeps a
    // home folder with spaces in it safe.
    startUnitProc.command = force
      ? ["sh", "-c",
         "touch \"$1/.local/state/omarchy-backups/force-after-restore\"; "
         + "exec systemctl start --no-block oma-backups-backup.service",
         "sh", root.home]
      : ["systemctl", "start", "--no-block", "oma-backups-backup.service"]
    startUnitProc.running = true
  }

  // Opening a restore point: oma-backups-browse@TS mounts it read-only and
  // writes /run/omarchy-backups-browse/TS.json when ready (or on error).
  property string browseTs: ""
  property string browsePhase: ""   // "", "opening", "open"
  property int browseWaited: 0
  // "open" in Files, "restore" (Restore my files), or "pick" (choosing what
  // to leave out — the restore point has to be mounted to point a file
  // chooser at it).
  property string browseMode: "open"
  // Where the open restore point's copy of the home folder is mounted. Picked
  // paths are turned into entries relative to it, so they mean the same thing
  // next time it is mounted somewhere else.
  property string browsePath: ""
  property bool pickWantFile: false
  property int browseMissed: 0

  // After a "system + settings" restore: which restore point still has the
  // user's files (written by restore-to-disk.sh into their state folder).
  property string partialSnapshot: ""
  property bool restoringFiles: false
  property int restorePercent: 0
  // What the quick restore left in the system area (AI models), still to put
  // back, and whether the files themselves are back already.
  property int skippedSystem: 0
  property bool filesDone: false
  // "waiting" while the terminal that puts the models back is open. It can't
  // be watched directly (the launcher returns at once), so the terminal
  // leaves a note when it's done.
  property string systemPhase: ""
  property bool systemAsked: false
  readonly property string putBackNote: root.home + "/.local/state/omarchy-backups/put-back-system.done"

  function restoreMyFiles() {
    if (root.partialSnapshot === "" || !root.linked) return
    // The models first, while someone is here to type the password.
    if (root.skippedSystem > 0 && !root.systemAsked) {
      putBackModels()
      return
    }
    if (root.filesDone) return
    root.restoringFiles = true
    root.restorePercent = 0
    browse(root.partialSnapshot, "restore")
  }

  function putBackModels() {
    if (root.systemPhase === "waiting") return
    root.systemPhase = "waiting"
    root.lastError = ""
    Quickshell.execDetached(["rm", "-f", root.putBackNote])
    // trap: Ctrl+C at the password prompt stops the command, not this shell,
    // so the note still gets written and the panel moves on.
    var inner = "rm -f " + root.shQuote([root.putBackNote]) + "; trap true INT; "
      + root.shQuote([root.cli, "put-back-system"]) + "; printf '%s' $? > " + root.shQuote([root.putBackNote])
    var term = "omarchy-launch-floating-terminal-with-presentation"
    Quickshell.execDetached(["sh", "-c",
      "if command -v " + term + " >/dev/null 2>&1; then exec " + term + " " + root.shQuote([inner]) + "; fi; "
      + "notify-send -a OmaBackups 'OmaBackups needs a terminal window' "
      + "\"Couldn't open one. Run this in a terminal instead: oma-backups put-back-system\""])
  }

  // The terminal finished (rc), or the user chose to carry on without it.
  function putBackFinished(rc) {
    if (root.systemPhase !== "waiting") return
    root.systemPhase = ""
    root.systemAsked = true
    Quickshell.execDetached(["rm", "-f", root.putBackNote])
    if (rc !== 0 && rc !== null)
      root.lastError = "Your AI models weren't put back. Press \"Put AI models back\" to try again."
    partialFile.reload()
    // Straight on to the files, unless they're already back.
    if (!root.filesDone && root.partialSnapshot !== "") {
      root.restoringFiles = true
      root.restorePercent = 0
      browse(root.partialSnapshot, "restore")
    }
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
    root.browseMissed = 0
    root.lastError = ""
    browsePoll.interval = 500
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
    forgetBrowse()
  }

  // The session has ended — either we stopped it, or it ended without us.
  // Only the panel's own state is cleared here; there is nothing left to stop.
  function forgetBrowse() {
    browsePoll.stop()
    root.browseTs = ""
    root.browsePhase = ""
    root.browsePath = ""
    root.browseMissed = 0
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
  // Restore points that must never be thinned away: a restore left something
  // behind on them on purpose, so they hold the only copy of it. The system
  // carries on backing up as normal around them — earmarking one is cheaper
  // than pausing everything until the user comes back for it.
  property var keptPoints: ({})
  readonly property int keptCount: Object.keys(root.keptPoints).length

  function isKept(ts) { return root.keptPoints.hasOwnProperty(ts) }

  function keptLeftOut(ts) {
    var e = root.keptPoints[ts]
    return (e && Array.isArray(e.left_out)) ? e.left_out : []
  }

  function releaseKept(ts) {
    if (!root.isKept(ts)) return
    keptPointProc.command = ["python3", root.keptPointsCli, "--remove", ts]
    keptPointProc.running = true
  }

  Process {
    id: keptPointProc
    onExited: {
      keptFile.reload()
      // Only set when this ran as the last step of a restore.
      if (root._afterKeep) {
        root._afterKeep = false
        root.runFinishFiles()
      }
    }
  }
  property bool _afterKeep: false

  FileView {
    id: keptFile
    path: root.home + "/.local/state/omarchy-backups/kept-points.json"
    printErrors: false
    onLoaded: {
      try {
        var j = JSON.parse(text())
        root.keptPoints = (j && typeof j === "object") ? j : ({})
      } catch (e) {
        root.keptPoints = ({})
      }
    }
    onLoadFailed: root.keptPoints = ({})
  }

  // What to leave out of "Restore my files" — a different question from the
  // backup skip list above. That one is "is this worth keeping a copy of";
  // this is "will it fit on the disk I am restoring onto, today". Empty by
  // default: a restore brings everything back unless told otherwise.
  ListModel { id: restoreSkipListModel }
  readonly property var restoreSkipModel: restoreSkipListModel
  readonly property int restoreSkipCount: restoreSkipListModel.count

  function hasRestoreSkip(path) {
    for (var i = 0; i < restoreSkipListModel.count; i++) {
      if (restoreSkipListModel.get(i).path === path) return true
    }
    return false
  }

  function loadRestoreSkips() {
    loadRestoreSkipProc.command = ["python3", root.writeRestoreSkip, "--list"]
    loadRestoreSkipProc.running = true
  }

  function persistRestoreSkips() {
    var args = ["python3", root.writeRestoreSkip]
    for (var i = 0; i < restoreSkipListModel.count; i++) args.push(restoreSkipListModel.get(i).path)
    persistRestoreSkipProc.command = args
    persistRestoreSkipProc.running = true
  }

  function addRestoreSkip(path) {
    if (!path) return
    var p = String(path).replace(/\/+$/, "")
    if (p === "") return
    if (root.hasRestoreSkip(p)) return
    Qt.callLater(function () {
      restoreSkipListModel.append({ path: p })
      root.persistRestoreSkips()
    })
  }

  function removeRestoreSkip(path) {
    var target = path
    Qt.callLater(function () {
      for (var i = restoreSkipListModel.count - 1; i >= 0; i--) {
        if (restoreSkipListModel.get(i).path === target) restoreSkipListModel.remove(i)
      }
      root.persistRestoreSkips()
    })
  }

  Process {
    id: loadRestoreSkipProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        restoreSkipListModel.clear()
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim()
          if (line && line.indexOf("#") !== 0) restoreSkipListModel.append({ path: line })
        }
      }
    }
  }

  Process { id: persistRestoreSkipProc }

  ListModel { id: skipListModel }
  readonly property var skipModel: skipListModel
  readonly property int skipCount: skipListModel.count

  function hasSkip(path) {
    for (var i = 0; i < skipListModel.count; i++) {
      if (skipListModel.get(i).path === path) return true
    }
    return false
  }

  function shQuote(argv) {
    return argv.map(function (a) {
      return "'" + String(a).replace(/'/g, "'\\''") + "'"
    }).join(" ")
  }

  function privileged(args) {
    // Always a visible terminal: sudo/pkexec's own auth prompt (password
    // or fingerprint) happens before our code even runs, so a hidden
    // pkexec route can't show progress for it either way — the terminal
    // is the one place that prompt is actually visible.
    //
    // Wrapped in sh so a missing terminal helper says so. Detached, this used
    // to fail invisibly: the button clicked, nothing happened, no explanation.
    var inner = root.shQuote(["sudo", root.cli].concat(args))
    var term = "omarchy-launch-floating-terminal-with-presentation"
    Quickshell.execDetached(["sh", "-c",
      "if command -v " + term + " >/dev/null 2>&1; then exec " + term + " " + inner + "; fi; "
      + "notify-send -a OmaBackups 'OmaBackups needs a terminal window' "
      + "\"Couldn't open one. Run this in a terminal instead: " + inner + "\""])
  }

  function refresh() {
    refreshing = true
    if (!detectProc.running) {
      _detectOut = ""
      detectProc.command = [root.cli, "detect", "--json"]
      detectProc.running = true
    }
    if (!statusProc.running) statusProc.running = true
    // No refreshSnapshots() here: `detect` rewrites the restore-point cache as
    // part of its own scan, and snapFile below watches that file — so this was
    // a second python process every two seconds for an answer already coming.
    // Also catches pairing/unpairing: the file may not exist to be watched.
    rootCopyFile.reload()
    keptFile.reload()
    remoteFile.reload()
    scheduleFile.reload()
    timerFile.reload()
    linkedFile.reload()
    lastSuccessFile.reload()
    if (!root.restoringFiles) partialFile.reload()
    if (root.systemPhase === "waiting") putBackFile.reload()
    nowSec = Date.now() / 1000
    if (!skipLoaded) loadSkipFile()
    if (!restoreSkipLoaded && root.partialSnapshot !== "") {
      restoreSkipLoaded = true
      loadRestoreSkips()
    }
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

  // force: this system came back from a partial restore and the user has
  // deliberately chosen to back it up anyway (Ctrl + Backup now), keeping
  // only what's on it. Automatic backups never take this path.
  function startBackup(force) {
    root.pendingForce = force === true
    compileThen("backup")
  }

  property bool pendingForce: false

  // Stopping takes a moment (a Pi has to lock its disk over the network).
  // Until the backup has really exited, say so instead of flipping between
  // "running" and "Resume" as the status catches up.
  property bool stopping: false
  property real stoppingSince: 0

  function stopBackup() {
    pendingStop = true
    pendingBackup = false
    pendingForce = false
    pendingFirstRunDisk = ""
    launchedBackup = false
    sawBackupStatus = false
    stopping = true
    stoppingSince = Date.now() / 1000
    backupRunning = true
    progressLabel = "Stopping and locking the backup disk"
    progressBusy = true
    progressDetail = ""
    if (root.linked)
      Quickshell.execDetached(["systemctl", "stop", "oma-backups-backup.service", "oma-backups-scheduled.service"])
    else
      privileged(["stop"])
  }

  function openSnapshot(ts) {
    if (!ts) return
    // Opening another restore point unmounts this one, and the restore is
    // copying out of it. Say so rather than killing it halfway.
    if (root.restoringFiles) {
      root.lastError = "Your files are still being restored. Press Stop first, or let it finish."
      return
    }
    if (root.linked) { browse(ts); return }
    if (root.remoteActive) {
      // Clicking did nothing whatsoever before this.
      root.lastError = "To open a restore point kept on " + root.remoteHost
        + ", press \"Stop asking for my password\" above first."
      return
    }
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

  function makeRescueStick(disk) {
    if (!disk) return
    privileged(["rescue-stick", disk])
  }

  function pickFolder() { pickProc.command = ["python3", root.picker]; pickProc.running = true }
  function pickFile() { pickProc.command = ["python3", root.picker, "--file"]; pickProc.running = true }

  // Choosing what to leave out of the restore means choosing from what is on
  // the backup, not from this half-empty system — so the restore point has to
  // be open before the chooser can be pointed at it. It stays open afterwards:
  // picking three folders should not unlock the disk three times.
  function pickInRestorePoint(wantFile) {
    if (root.partialSnapshot === "") return
    root.pickWantFile = wantFile === true
    if (root.browseTs === root.partialSnapshot && root.browsePhase === "open" && root.browsePath !== "") {
      root.launchRestorePicker()
      return
    }
    root.browse(root.partialSnapshot, "pick")
  }

  function launchRestorePicker() {
    var cmd = ["python3", root.picker, "--root", root.browsePath,
      "--title", root.pickWantFile ? "Leave this file out of the restore"
        : "Leave this folder out of the restore"]
    if (root.pickWantFile) cmd.push("--file")
    pickProc.command = cmd
    pickProc.running = true
  }

  property string _pickOut: ""
  Process {
    id: pickProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._pickOut = String(text || "").trim()
    }
    onExited: function (code) {
      if (code === 0 && root._pickOut !== "") {
        var p = String(root._pickOut)
        if (p.indexOf("file://") === 0) p = decodeURIComponent(p.slice(7))
        if (root.browseMode === "pick") {
          // Stored relative to the mount, with a leading slash so rsync
          // anchors it at the top of the home folder rather than matching
          // the same name anywhere below it.
          var rel = p.slice(root.browsePath.length)
          if (rel.charAt(0) !== "/") rel = "/" + rel
          root.addRestoreSkip(rel)
        } else {
          root.addSkip(p)
        }
        return
      }
      if (code === 3) {
        root.lastError = "That isn't inside the restore point. Pick something from the backup's own copy."
        return
      }
      // 1 is "cancelled", which needs no comment. 2 is the picker not being
      // installed — the button did nothing at all and said nothing either.
      if (code === 2)
        root.lastError = "Couldn't open the file chooser. Install it with:  sudo pacman -S python-gobject gtk3"
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
        if (!root.backupRunning) root.lastError = root.backupError
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

  // Two things read the backup's status, and they are not equally informed.
  // `oma-backups status` checks the pid behind the file and marks a reading
  // "stale"; the file itself is watched as well, because that arrives the
  // instant it changes, but it cannot tell a live backup from one that was
  // killed before it could write "idle". So the file is allowed to keep a
  // backup we already know about up to date, and nothing more: on its own it
  // asks the CLI rather than declaring a backup running. Without that, one
  // leftover status file pinned the panel to a backup that no longer existed.
  function applyStatusText(raw, authoritative) {
    raw = String(raw || "").trim()
    if (!raw) return
    var j
    try { j = JSON.parse(raw) } catch (e) { return }
    if (!j || typeof j !== "object") return
    if (root.stopping) {
      if (!authoritative) return
      var stillGoing = j.running === true && j.stale !== true && j.phase !== "idle"
      if (stillGoing && Date.now() / 1000 - root.stoppingSince < 60) {
        root.backupRunning = true
        root.progressLabel = "Stopping and locking the backup disk"
        root.progressBusy = true
        root.progressDetail = ""
        return
      }
      root.stopping = false
      root.backupRunning = false
      root.launchedBackup = false
      root.sawBackupStatus = false
    }
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
        if (j.line) root.backupError = root.lastError = String(j.line)
      }
    } else if (j.stale === true) {
      if (root.launchedBackup && j.phase !== "error") root.backupRunning = true
      else if (typeof j.running === "boolean") root.backupRunning = false
    } else if (j.running === true) {
      if (authoritative || root.launchedBackup || root.backupRunning || root.stopping) {
        root.backupRunning = true
        root.sawBackupStatus = true
        root.backupError = ""
      } else {
        // A file we weren't expecting says a backup is running. Ask the one
        // reading that knows leftover from live, and decide on its answer.
        if (!statusProc.running) statusProc.running = true
        return
      }
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
    root.overallPercent = typeof j.overall_percent === "number" ? j.overall_percent : 0
    root.overallStep = typeof j.overall_step === "number" ? j.overall_step : 0
    root.overallSteps = typeof j.overall_steps === "number" ? j.overall_steps : 0
    root.overallEta = j.overall_eta ? String(j.overall_eta) : ""
    root.overallTotalTime = j.overall_total_time ? String(j.overall_total_time) : ""
    root.elapsedText = j.elapsed ? String(j.elapsed) : ""
    if (j.phase) root.statusLine = Model.phaseLabel(j.phase) + "  " + root.progressPercent + "%"
  }

  FileView {
    id: statusFile
    path: "/run/omarchy-backups.status"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyStatusText(text(), false)
    onFileChanged: reload()
  }

  Process {
    id: statusProc
    command: [root.cli, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatusText(text, true)
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
        root.lastError = root.backupError = ""
        root.backupRunning = true
        root.launchedBackup = true
        root.sawBackupStatus = false
        root.privileged(["first-run", disk])
      } else if (root.pendingBackup) {
        root.pendingBackup = false
        var forced = root.pendingForce
        root.pendingForce = false
        root.lastError = root.backupError = ""
        root.backupRunning = true
        root.launchedBackup = true
        root.sawBackupStatus = false
        if (root.linked) root.startBackupService(forced)
        else root.privileged(forced ? ["backup", "--yes", "--force-after-restore"]
                                    : ["backup", "--yes"])
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
      if (root.browseTs === "") return
      if (root.browsePhase === "open") {
        // Its state file lives exactly as long as the session does. If it has
        // gone, the browse ended without us: stopped from a terminal, the Pi
        // dropped, or it was killed. Saying "Browsing…" and keeping Backup
        // now paused after that leaves the panel stuck with no way out.
        if (root._browseOut === "") {
          root.browseMissed += 1
          // Two in a row, so a single unlucky read doesn't end a good session.
          if (root.browseMissed >= 2 && !root.restoringFiles) {
            root.forgetBrowse()
            root.refresh()
          }
        } else {
          root.browseMissed = 0
        }
        return
      }
      if (root.browsePhase !== "opening" || root._browseOut === "") return
      var j
      try { j = JSON.parse(root._browseOut) } catch (e) { return }
      if (j.state === "ready" && j.path) {
        root.browsePhase = "open"
        root.browsePath = String(j.path)
        root.browseMissed = 0
        // Keep the timer going, slower: from here it is watching for the
        // session ending rather than waiting for it to start.
        browsePoll.interval = 2000
        if (root.browseMode === "restore") {
          // Only what's missing: never overwrite anything changed since.
          var cmd = ["rsync", "-a", "--ignore-existing", "--info=progress2"]
          for (var k = 0; k < restoreSkipListModel.count; k++)
            cmd.push("--exclude=" + restoreSkipListModel.get(k).path)
          cmd.push(String(j.path) + "/", root.home + "/")
          restoreProc.command = cmd
          restoreProc.running = true
        } else if (root.browseMode === "pick") {
          root.launchRestorePicker()
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
      // Stopped from the panel, or overtaken by a restore point the user has
      // since opened: either way this copy no longer owns the browse session,
      // and closing it here shut a window they were reading.
      if (!root.restoringFiles) return
      root.restoringFiles = false
      if (root.browseMode === "restore") root.closeBrowse()
      if (code === 0) {
        // Everything's back: the protected restore point can be thinned again.
        // Unless the AI models are still on the backup: then the marker stays
        // (backups stay paused, the restore point stays protected) and only
        // records that the files are done. Decided from the file itself, as
        // the terminal may have changed it since the panel last read it.
        // Things left out on purpose do not hold the restore open any more:
        // the restore point they are on is earmarked instead, and this system
        // goes back to backing up as normal.
        root._leftOutAtFinish = root.restoreSkipCount
        if (root.restoreSkipCount > 0 && root.partialSnapshot !== "") {
          var mark = ["python3", root.keptPointsCli, "--add", root.partialSnapshot]
          for (var n = 0; n < restoreSkipListModel.count; n++)
            mark.push(restoreSkipListModel.get(n).path)
          root._afterKeep = true
          keptPointProc.command = mark
          keptPointProc.running = true
        } else {
          root.runFinishFiles()
        }
      } else {
        root.lastError = "Restoring your files stopped before finishing. Press Restore my files to carry on."
      }
    }
  }

  // $1 the marker, $2 "1" when folders were left out on purpose. The marker
  // only goes when everything really is back: while it is there, backups stay
  // paused and this restore point is never thinned away, which is the only
  // thing keeping what was left out reachable.
  readonly property string finishFilesScript:
    "f=\"$1\"; if jq -e '(.skipped_system // []) | length > 0' \"$f\" >/dev/null 2>&1; then "
    + "jq '.files_done = true' \"$f\" > \"$f.tmp\" && mv \"$f.tmp\" \"$f\" && echo models; "
    + "else rm -f \"$f\"; echo done; fi"

  function runFinishFiles() {
    finishFilesProc.command = ["sh", "-c", root.finishFilesScript, "sh",
      root.home + "/.local/state/omarchy-backups/partial-restore.json"]
    finishFilesProc.running = true
  }

  Process {
    id: finishFilesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var outcome = String(text || "").trim()
        var left = root._leftOutAtFinish
        root._leftOutAtFinish = 0
        if (outcome === "models") {
          root.filesDone = true
          Quickshell.execDetached(["notify-send", "-a", "OmaBackups", "Your files are back",
            "Your AI models are still on the backup. Press \"Put AI models back\" in OmaBackups."])
        } else {
          root.partialSnapshot = ""
          root.skippedSystem = 0
          root.filesDone = false
          // The list belonged to this restore; it goes with it, or the next
          // one silently starts with someone else's answer to "too big".
          restoreSkipListModel.clear()
          root.persistRestoreSkips()
          root.restoreSkipLoaded = false
          Quickshell.execDetached(["notify-send", "-a", "OmaBackups", "Your files are back",
            left > 0
              ? "Backups start again now. The restore point you left " + left
                + (left === 1 ? " thing" : " things") + " on is kept for as long as you want it."
              : "Everything from the backup has been restored to your home folder."])
        }
        partialFile.reload()
      }
    }
  }

  FileView {
    id: putBackFile
    path: root.putBackNote
    printErrors: false
    onLoaded: {
      var rc = parseInt(String(text()).trim(), 10)
      root.putBackFinished(isNaN(rc) ? null : rc)
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
        root.skippedSystem = Array.isArray(j.skipped_system) ? j.skipped_system.length : 0
        root.filesDone = j.files_done === true
      } catch (e) {
        root.partialSnapshot = ""
        root.skippedSystem = 0
        root.filesDone = false
      }
    }
    onLoadFailed: {
      root.partialSnapshot = ""
      root.skippedSystem = 0
      root.filesDone = false
    }
  }

  Timer {
    id: browsePoll
    interval: 500
    repeat: true
    onTriggered: {
      if (root.browsePhase === "opening") {
        root.browseWaited += 1
        if (root.browseWaited > 120) {
          root.lastError = "Opening that restore point timed out."
          root.closeBrowse()
          return
        }
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

  // link.sh writes this copy; its absence means OmaBackups has never been
  // linked on this machine, and the home links are all there is.
  FileView {
    id: rootCopyFile
    path: "/usr/local/lib/oma-backups/VERSION"
    printErrors: false
    onLoaded: root.hasRootCopy = true
    onLoadFailed: root.hasRootCopy = false
  }

  FileView {
    id: linkedFile
    path: "/etc/omarchy-backups/linked.json"
    printErrors: false
    onLoaded: root.linked = true
    onLoadFailed: root.linked = false
  }

  FileView {
    id: versionFile
    path: root.shareRoot + "/VERSION"
    printErrors: false
    onLoaded: root.version = String(text()).trim()
  }

  // Idle cost matters: the bar runs from login to logout, panel open or not.
  // Both of these used to run flat out the whole time — a status call twice a
  // second and a full disk scan every two seconds, forever, for about 9% of a
  // core. Everything that changes on its own (the status file, the
  // restore-point list, the Pi pairing, the schedule, the timer unit) is
  // watched by a FileView below and arrives the moment it changes, so polling
  // is only needed for the two things no file can tell us about: how far a
  // running backup has got, and a disk being plugged in while you are looking
  // at the list.
  Timer {
    interval: 500
    running: root.backupRunning || root.launchedBackup || root.stopping || root.restoringFiles
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statusProc.running) statusProc.running = true
  }
  Timer {
    interval: 2000
    running: root.panelOpen || root.backupRunning || root.launchedBackup
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
