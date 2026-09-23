import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "oma.backups"
  ipcTarget: "oma.backups"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  // The theme's own accent rather than a colour of our own, so this follows
  // whatever Omarchy is wearing. Not `urgent` — nothing is wrong with a kept
  // restore point. On a theme where accent sits close to the ordinary text
  // the row still reads as different: it is the only one carrying buttons.
  readonly property color kept: Color.accent
  // Which restore point has been asked about: letting one go is not something
  // a stray click should do.
  property string releaseAsk: ""
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  property string page: "home"
  property bool showAllSnaps: false
  // A system restored without its files: backups are paused so this machine
  // can't overwrite the real backup with the gap. Holding Ctrl wakes the
  // Backup now button for a one-off forced backup; automatic backups stay
  // off until the files are back or a forced backup settles it.
  readonly property bool blockedByRestore: svc.partialSnapshot !== ""
  // A restore point open for browsing keeps the backup disk (or the Pi's)
  // unlocked, and a backup would lock it again on its way out — from under the
  // window still being read. Same device as blockedByRestore: the button goes
  // quiet and says why. No Ctrl override here; pressing Done is the answer.
  readonly property bool blockedByBrowse: svc.browseTs !== "" && !svc.restoringFiles
  readonly property bool backupBlocked: blockedByRestore || blockedByBrowse
  readonly property bool backupGreyed: (blockedByRestore && !ctrlHeld) || blockedByBrowse
  property bool ctrlHeld: false
  property bool forceAsked: false
  property bool forceConfirmed: false
  // Named categories rather than a size rule, and close to the set Pika
  // Backup offers, so anyone who has met one of these tools recognises them.
  // Each is something that can be downloaded or made again. `paths` are skip
  // list entries (relative to /home); `restorePaths` say the same thing
  // relative to one home folder inside a restore point, which is what
  // "Restore my files" copies from.
  readonly property var quickSkips: [
    { label: "Downloads", note: "",
      paths: [svc.home + "/Downloads"],
      restorePaths: ["/Downloads"] },
    { label: "Caches", note: "Made again whenever they're needed",
      paths: [".cache", ".thumbnails", svc.home + "/.var/app/*/cache"],
      restorePaths: ["/.cache", "/.thumbnails", "/.var/app/*/cache"] },
    { label: "Trash", note: "Files you have already thrown away",
      paths: ["**/.local/share/Trash", ".Trash", "lost+found"],
      restorePaths: ["/.local/share/Trash", "/.Trash", "lost+found"] },
    { label: "Flatpak apps", note: "The apps themselves — their documents and settings still come back",
      paths: [svc.home + "/.local/share/flatpak"],
      restorePaths: ["/.local/share/flatpak"] },
    { label: "Virtual machines and containers", note: "May hold things kept inside them",
      paths: [svc.home + "/.local/share/containers", svc.home + "/.local/share/docker",
        svc.home + "/.local/share/libvirt", svc.home + "/.local/share/gnome-boxes",
        svc.home + "/.local/share/bottles", svc.home + "/.var/app/org.gnome.Boxes",
        svc.home + "/.var/app/com.usebottles.bottles"],
      restorePaths: ["/.local/share/containers", "/.local/share/docker",
        "/.local/share/libvirt", "/.local/share/gnome-boxes",
        "/.local/share/bottles", "/.var/app/org.gnome.Boxes",
        "/.var/app/com.usebottles.bottles"] },
    { label: "AI models", note: "Large downloads you can fetch again",
      paths: [svc.home + "/.lmstudio/models", svc.home + "/.ollama/models",
        svc.home + "/.local/share/nomic.ai", svc.home + "/.local/share/Jan"],
      restorePaths: ["/.lmstudio/models", "/.ollama/models",
        "/.local/share/nomic.ai", "/.local/share/Jan"] },
    { label: "Game libraries", note: "Games you can install again",
      paths: [svc.home + "/.steam", svc.home + "/.local/share/Steam"],
      restorePaths: ["/.steam", "/.local/share/Steam"] }
  ]

  // In restore mode the same switches drive the restore skip list instead.
  function quickSkipPaths(entry) {
    return root.blockedByRestore ? entry.restorePaths : entry.paths
  }

  function quickSkipOn(entry) {
    var paths = root.quickSkipPaths(entry)
    for (var i = 0; i < paths.length; i++) {
      if (root.blockedByRestore ? !svc.hasRestoreSkip(paths[i]) : !svc.hasSkip(paths[i])) return false
    }
    return true
  }

  function isQuickSkip(path) {
    for (var i = 0; i < quickSkips.length; i++) {
      if (quickSkips[i].paths.indexOf(path) !== -1) return true
      if (quickSkips[i].restorePaths.indexOf(path) !== -1) return true
    }
    return false
  }

  // "Use a different disk": every eligible disk except the current backup disk.
  property string newDisk: ""
  property bool newDiskConfirmed: false
  property string stickDisk: ""
  property bool stickConfirmed: false
  // USBs that could become a network rescue stick: never a backup disk.
  readonly property var stickDisks: {
    var out = []
    for (var i = 0; i < svc.disks.length; i++)
      if (!svc.disks[i].capsule && svc.disks[i].kind !== "capsule") out.push(svc.disks[i])
    return out
  }
  readonly property var otherDisks: {
    var out = []
    var cur = svc.capsule ? svc.capsule.path : ""
    for (var i = 0; i < svc.disks.length; i++)
      if (svc.disks[i].path !== cur) out.push(svc.disks[i])
    return out
  }

  readonly property int customSkipCount: {
    var n = 0, m = root.blockedByRestore ? svc.restoreSkipModel : svc.skipModel
    var c = root.blockedByRestore ? svc.restoreSkipCount : svc.skipCount
    for (var i = 0; i < c; i++) if (!isQuickSkip(m.get(i).path)) n++
    return n
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  property real spin: 0

  onOpenedChanged: {
    svc.panelOpen = opened
    if (opened) {
      svc.refresh()
      Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    } else {
      page = "home"
      showAllSnaps = false
      newDisk = ""
      newDiskConfirmed = false
      ctrlHeld = false
      forceAsked = false
      forceConfirmed = false
      stickDisk = ""
      stickConfirmed = false
    }
  }

  Service { id: svc }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { svc.refresh(); return "ok" }
    function settings(): void { root.page = "settings"; root.open() }
  }

  NumberAnimation on spin {
    running: svc.backupRunning
    loops: Animation.Infinite
    from: 0
    to: 360
    duration: 800
  }

  Component {
    id: safeIcon
    Item {
      readonly property color tint: svc.backupRunning ? root.urgent : root.foreground

      Image {
        id: safeBodyImg
        anchors.fill: parent
        source: "safe-body.png"
        fillMode: Image.PreserveAspectFit
        visible: false
        layer.enabled: true
      }
      MultiEffect {
        anchors.fill: safeBodyImg
        source: safeBodyImg
        colorization: 1.0
        colorizationColor: parent.tint
      }

      // Only the dial wheel spins during a backup — the safe body and
      // its ring/bezel stay put. Two separately-cropped image layers of
      // the same source icon, overlaid so they read as one icon at rest.
      Image {
        id: safeDialImg
        anchors.fill: parent
        source: "safe-dial.png"
        fillMode: Image.PreserveAspectFit
        visible: false
        layer.enabled: true
      }
      MultiEffect {
        anchors.fill: safeDialImg
        source: safeDialImg
        colorization: 1.0
        colorizationColor: parent.tint
        rotation: svc.backupRunning ? root.spin : 0
        transformOrigin: Item.Center
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: safeIcon
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: svc.backupRunning
      ? ("OmaBackups — " + svc.progressText)
      : (svc.hasCapsule ? "OmaBackups" : "OmaBackups — set up a disk")
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.page === "settings") root.page = "home"
        else root.close()
      }
      onActivateRequested: {}
      onTextKey: function (t) {
        if (t === "b" || t === "B") {
          if (svc.hasCapsule && !svc.backupRunning && !root.backupBlocked) svc.startBackup()
        } else if (t === "s" || t === "S") {
          if (svc.backupRunning) svc.stopBackup()
        } else if (t === "r" || t === "R") {
          svc.refresh()
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // —— Home ——
          Column {
            visible: root.page === "home"
            width: parent.width
            spacing: Style.space(12)

            Item {
              width: parent.width
              height: hero.implicitHeight
              PanelHero {
                id: hero
                anchors.left: parent.left
                anchors.right: gearBtn.left
                anchors.rightMargin: Style.space(8)
                title: "OmaBackups"
                meta: svc.backupRunning
                  ? svc.progressText
                  : (svc.hasCapsule ? (svc.lastSnapshot ? ("Last copy  " + svc.lastSnapshot) : ("Ready  ·  " + svc.version)) : (svc.version + "  ·  no backup disk yet"))
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Button {
                id: gearBtn
                anchors.right: parent.right
                anchors.top: parent.top
                text: "\uf013"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                tooltipText: "Settings"
                onClicked: root.page = "settings"
              }
            }

            Column {
              visible: svc.hasCapsule && svc.capsuleDisk !== null
              width: parent.width
              spacing: Style.space(4)
              Text {
                width: parent.width
                text: {
                  var d = svc.capsuleDisk
                  if (!d) return ""
                  var where = svc.remoteActive ? (" on " + svc.remoteHost) : ""
                  return "Backup disk" + where + "  \u00b7  " + Model.formatSize(d.free) + " free of " + Model.formatSize(d.total)
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Rectangle {
                width: parent.width
                height: 6
                radius: 3
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                Rectangle {
                  readonly property real frac: {
                    var d = svc.capsuleDisk
                    if (!d || !d.total) return 0
                    return Math.min(1, Math.max(0, d.used / d.total))
                  }
                  width: Math.max(6, parent.width * frac)
                  height: parent.height
                  radius: 3
                  color: frac > 0.9 ? root.urgent : root.dim
                }
              }
            }

            Text {
              visible: svc.remoteActive && svc.capsuleDisk === null
              width: parent.width
              text: "Backup disk on " + svc.remoteHost + "  ·  locked between backups"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: svc.lastError !== ""
              width: parent.width
              text: svc.lastError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Column {
              visible: svc.backupRunning || svc.launchedBackup
              width: parent.width
              spacing: Style.space(6)
              Text {
                width: parent.width
                text: svc.progressText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Rectangle {
                id: progressTrack
                width: parent.width
                height: 8
                radius: 4
                clip: true
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                // A step with a real percentage.
                Rectangle {
                  visible: !svc.progressBusy
                  width: Math.max(8, parent.width * Math.min(100, Math.max(0, svc.progressPercent)) / 100)
                  height: parent.height
                  radius: 4
                  color: Color.accent
                }
                // A step with nothing to measure: a moving "working" segment
                // instead of a made-up number.
                Rectangle {
                  id: busySegment
                  visible: svc.progressBusy
                  width: parent.width * 0.3
                  height: parent.height
                  radius: 4
                  color: Color.accent
                  SequentialAnimation on x {
                    running: busySegment.visible
                    loops: Animation.Infinite
                    NumberAnimation { from: -busySegment.width; to: progressTrack.width; duration: 1400; easing.type: Easing.InOutQuad }
                  }
                }
              }
              Text {
                visible: text !== ""
                width: parent.width
                text: svc.progressDetail !== "" ? svc.progressDetail
                  : [svc.progressSpeed, svc.progressEta ? ("ETA " + svc.progressEta) : ""].filter(function (s) { return s && s.length }).join("   ")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              // The second bar: the whole backup, not just this step. Thinner
              // and dimmer, because the step above is what's happening now.
              Column {
                visible: svc.hasOverall
                width: parent.width
                spacing: Style.space(4)
                Item { width: 1; height: Style.space(2) }
                Text {
                  width: parent.width
                  text: svc.overallText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
                Rectangle {
                  width: parent.width
                  height: 5
                  radius: 3
                  clip: true
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                  Rectangle {
                    width: Math.max(5, parent.width * Math.min(100, Math.max(0, svc.overallPercent)) / 100)
                    height: parent.height
                    radius: 3
                    color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)
                  }
                }
                Text {
                  visible: text !== ""
                  width: parent.width
                  text: svc.overallDetail
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }
            }

            Item {
              width: parent.width
              height: backupBtn.implicitHeight
              visible: svc.hasCapsule && !svc.backupRunning && !svc.launchedBackup
              Button {
                id: backupBtn
                width: parent.width
                // "Resume" belongs to a backup that was interrupted and can
                // carry on. The only press available while a restore has this
                // paused is a Ctrl-held forced one, which starts a fresh
                // backup of what is here -- nothing is being resumed.
                text: (svc.backupIncomplete && !root.blockedByRestore) ? "Resume backup" : "Backup now"
                // Greyed out while this system is missing its files (lit again
                // for as long as Ctrl is held), and while a restore point is
                // open for browsing (no override — press Done).
                foreground: root.backupGreyed ? root.dim : Color.background
                background: root.backupGreyed ? "transparent" : Color.accent
                bordered: root.backupGreyed
                accent: Color.accent
                enabled: !root.backupBlocked
                fontFamily: root.fontFamily
                onClicked: svc.startBackup()
              }
              // The shared Button's clicked() carries no modifiers, so the
              // blocked case gets its own layer on top: it reads Ctrl at
              // click time and only ever opens the warning below.
              MouseArea {
                anchors.fill: parent
                visible: root.blockedByRestore && !root.blockedByBrowse
                enabled: root.blockedByRestore && !root.blockedByBrowse
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: root.ctrlHeld ? Qt.PointingHandCursor : Qt.ArrowCursor
                onPositionChanged: function (mouse) {
                  root.ctrlHeld = (mouse.modifiers & Qt.ControlModifier) !== 0
                }
                onExited: root.ctrlHeld = false
                onPressed: function (mouse) {
                  root.ctrlHeld = (mouse.modifiers & Qt.ControlModifier) !== 0
                  if (root.ctrlHeld) root.forceAsked = true
                }
              }
            }
            Text {
              visible: root.blockedByBrowse
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "Paused while a restore point is open. Press Done above to finish."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Text {
              visible: root.blockedByRestore && !root.forceAsked && !root.blockedByBrowse
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: (svc.filesDone ? "Paused until your AI models are back." : "Paused until your files are back.")
                + " Hold Ctrl to back up anyway."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Column {
              visible: root.blockedByRestore && root.forceAsked && !root.blockedByBrowse
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: parent.width
                text: "Backing up now keeps only what's on this system. Everything that "
                  + "didn't come back from " + Model.prettyStamp(svc.partialSnapshot)
                  + (svc.filesDone ? " — your AI models — is dropped from the "
                    : " — your documents, photos and other files"
                      + (svc.skippedSystem > 0 ? ", and your AI models" : "") + " — is dropped from the ")
                  + "backup's current copy and won't be in any new restore point. "
                  + "Older restore points still have it."
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Toggle {
                width: parent.width
                label: "I understand: keep only what's on this system"
                checked: root.forceConfirmed
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.forceConfirmed = !root.forceConfirmed
              }
              Button {
                width: parent.width
                text: "Back up anyway"
                foreground: root.urgent
                bordered: true
                enabled: root.forceConfirmed && !svc.backupRunning
                fontFamily: root.fontFamily
                onClicked: {
                  root.forceAsked = false
                  root.forceConfirmed = false
                  svc.startBackup(true)
                }
              }
              Button {
                width: parent.width
                text: "Cancel"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  root.forceAsked = false
                  root.forceConfirmed = false
                }
              }
            }
            Text {
              // Automatic backups really are off until the files are back --
              // the hourly check refuses, and says so in the log. Naming a
              // time they will happen at is just wrong.
              visible: svc.nextBackupText !== "" && !svc.backupRunning && !svc.launchedBackup
                && !root.blockedByRestore
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: svc.nextBackupText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Button {
              width: parent.width
              visible: (svc.backupRunning || svc.launchedBackup) && !svc.stopping
              text: "Stop backup"
              foreground: root.urgent
              bordered: true
              fontFamily: root.fontFamily
              onClicked: svc.stopBackup()
            }

            Rectangle {
              visible: svc.browseTs !== "" && (svc.browseMode === "open" || svc.browseMode === "pick")
              width: parent.width
              height: doneBtn.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: "transparent"
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
              border.width: 1
              Text {
                anchors.left: parent.left
                anchors.right: doneBtn.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                text: svc.browsePhase === "opening"
                  ? "Opening " + Model.prettyStamp(svc.browseTs) + "…"
                  : (svc.browseMode === "pick"
                    ? "Choosing from " + Model.prettyStamp(svc.browseTs) + "  ·  read-only"
                    : "Browsing " + Model.prettyStamp(svc.browseTs) + "  ·  read-only")
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Button {
                id: doneBtn
                anchors.right: parent.right
                anchors.rightMargin: Style.space(5)
                anchors.verticalCenter: parent.verticalCenter
                text: "Done"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                tooltipText: "Close it and lock the backup disk"
                onClicked: svc.closeBrowse()
              }
            }

            Button {
              width: parent.width
              visible: svc.hasCapsule && !svc.linked && !svc.backupRunning && !svc.launchedBackup
              text: "Stop asking for my password"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              tooltipText: "One-time setup: backing up and opening restore points won't ask again"
              onClicked: svc.linkLaptop()
            }

            Column {
              visible: svc.partialSnapshot !== ""
              width: parent.width
              spacing: Style.space(8)
              PanelSectionHeader {
                text: "YOUR FILES"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Text {
                width: parent.width
                text: svc.systemPhase === "waiting"
                  ? "Finish in the terminal window: it's putting your AI models back. Your files come next."
                  : svc.restoringFiles
                  ? (svc.browsePhase === "opening"
                    ? "Opening " + Model.prettyStamp(svc.partialSnapshot) + "…"
                    : "Restoring your files from " + Model.prettyStamp(svc.partialSnapshot) + "  ·  " + svc.restoreProgress)
                  : svc.filesDone
                  ? "Your files are back. Your AI models are still on the backup: they live in the "
                    + "system area, so putting them back needs your password."
                  : "Only your settings came back from " + Model.prettyStamp(svc.partialSnapshot)
                    + ". Your documents, photos and other files are still on the backup"
                    + (svc.skippedSystem > 0 ? ", and so are your AI models." : ".")
                    + (svc.linked ? "" : " Link this laptop (button above) to bring them back.")
                color: (svc.restoringFiles || svc.systemPhase === "waiting") ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Button {
                visible: !svc.restoringFiles && svc.systemPhase !== "waiting"
                width: parent.width
                text: svc.filesDone ? "Put AI models back" : "Restore my files"
                foreground: Color.background
                background: Color.accent
                accent: Color.accent
                enabled: svc.linked && svc.hasCapsule && !svc.backupRunning
                fontFamily: root.fontFamily
                tooltipText: svc.filesDone
                  ? "Opens a terminal to put your AI models back. Asks for your password."
                  : "Copies back everything that's missing. Never overwrites a file you've changed since."
                onClicked: svc.filesDone ? svc.putBackModels() : svc.restoreMyFiles()
              }
              Button {
                visible: !svc.restoringFiles && svc.systemPhase !== "waiting"
                width: parent.width
                text: svc.restoreSkipCount > 0
                  ? "Change what's left out  ·  " + svc.restoreSkipCount
                  : "Choose what to leave out"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                tooltipText: "For anything too big for this disk. Picked from the backup's own copy."
                onClicked: root.page = "settings"
              }
              Button {
                visible: svc.systemPhase === "waiting"
                width: parent.width
                text: "Carry on without the models"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                tooltipText: "Your files come back now. You can put the models back afterwards."
                onClicked: svc.putBackFinished(null)
              }
              Button {
                visible: svc.restoringFiles
                width: parent.width
                text: "Stop (carry on later)"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.stopRestoringFiles()
              }
            }

            Column {
              visible: svc.hasCapsule && !svc.backupRunning && !svc.launchedBackup
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: svc.snapshotCount ? ("RESTORE POINTS  ·  " + svc.snapshotCount) : "RESTORE POINTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Text {
                width: parent.width
                text: svc.snapshotCount === 0
                  ? "No dated copies yet. After a backup they appear here."
                  : (svc.remoteActive && !svc.linked
                    ? "Stored on " + svc.remoteHost + ". Link this laptop (below) to open them from here."
                    : "Open a date to browse that copy. " + (svc.schedule.retention === "smart"
                      ? "Smart thinning keeps every backup from the last day, one a day for a month, then one a week."
                      : "All restore points are kept.")
                    + (svc.keptCount > 0
                      ? " The marked ones still hold files a restore never brought back, so they "
                        + "are never thinned away. Press Restore on one to go and get them, or "
                        + "tap the row itself to stop keeping it."
                      : ""))
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Column {
                visible: root.releaseAsk !== "" && svc.isKept(root.releaseAsk)
                width: parent.width
                spacing: Style.space(8)
                Text {
                  width: parent.width
                  text: {
                    var l = svc.keptLeftOut(root.releaseAsk)
                    return Model.prettyStamp(root.releaseAsk) + " is kept because a restore left "
                      + (l.length ? l.join(", ") : "something")
                      + " on it. Let it go and it can be thinned away like any other, taking "
                      + "the last copy of that with it."
                  }
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
                Row {
                  spacing: Style.space(8)
                  Button {
                    text: "Let it go"
                    bordered: true
                    foreground: root.urgent
                    fontFamily: root.fontFamily
                    onClicked: {
                      var t = root.releaseAsk
                      root.releaseAsk = ""
                      svc.releaseKept(t)
                    }
                  }
                  Button {
                    text: "Keep it"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.releaseAsk = ""
                  }
                }
              }
              Repeater {
                model: svc.snapModel
                delegate: Rectangle {
                  required property int index
                  required property string whenText
                  required property string snapId
                  required property string sizeText
                  visible: root.showAllSnaps || index < 5
                  readonly property bool rpKeptRow: svc.isKept(snapId)
                  width: column.width
                  height: visible
                    ? (Math.max(rpTxt.implicitHeight, rpActions.implicitHeight) + Style.space(10))
                    : 0
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.color: rpKeptRow
                    ? root.kept
                    : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                  border.width: 1
                  Text {
                    id: rpTxt
                    anchors.left: parent.left
                    anchors.right: rpActions.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(6)
                    text: whenText
                    color: rpKeptRow ? root.kept : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  // Declared before the buttons so they take the clicks that
                  // land on them: a plain row opens the restore point, a
                  // marked one asks whether to stop keeping it (its own
                  // Browse button does the opening).
                  MouseArea {
                    anchors.fill: parent
                    enabled: svc.linked || !svc.remoteActive
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      if (rpKeptRow) root.releaseAsk = (root.releaseAsk === snapId ? "" : snapId)
                      else svc.openSnapshot(snapId)
                    }
                  }
                  Row {
                    id: rpActions
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(6)
                    Text {
                      // No anchors: Row positions its own children, and it is
                      // centred in the row itself.
                      visible: sizeText !== "" && !rpKeptRow
                      text: sizeText
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Button {
                      visible: rpKeptRow
                      text: "Browse"
                      bordered: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      horizontalPadding: Style.space(8)
                      verticalPadding: Style.space(4)
                      enabled: (svc.linked || !svc.remoteActive) && !svc.restoringFiles
                      tooltipText: "Open this restore point read-only"
                      onClicked: svc.openSnapshot(snapId)
                    }
                    Button {
                      visible: rpKeptRow
                      text: svc.restoreKeptTs === snapId
                        ? (svc.browsePhase === "opening" ? "Opening…"
                          : (svc.restoreCounting ? "Counting…" : svc.restorePercent + "%"))
                        : "Restore"
                      bordered: true
                      foreground: root.kept
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      horizontalPadding: Style.space(8)
                      verticalPadding: Style.space(4)
                      enabled: svc.linked && !svc.backupRunning
                        && (!svc.restoringFiles || svc.restoreKeptTs === snapId)
                      tooltipText: svc.restoreKeptTs === snapId
                        ? "Stop, and carry on another time"
                        : "Bring back what this one still holds. Never overwrites a file you have changed since."
                      onClicked: {
                        if (svc.restoreKeptTs === snapId) svc.stopRestoringFiles()
                        else svc.restoreKept(snapId)
                      }
                    }
                  }
                }
              }
              Button {
                visible: svc.snapshotCount > 5 && !root.showAllSnaps
                width: parent.width
                text: "More  ·  " + (svc.snapshotCount - 5) + " older"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.showAllSnaps = true
              }
              Button {
                visible: svc.snapshotCount > 5 && root.showAllSnaps
                width: parent.width
                text: "Show less"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.showAllSnaps = false
              }
            }

            Column {
              visible: !svc.hasCapsule && !svc.backupRunning && !svc.launchedBackup
              width: parent.width
              spacing: Style.space(10)
              Text {
                width: parent.width
                text: "Plug in a USB disk to keep copies of this computer."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Repeater {
                model: svc.disks
                delegate: Button {
                  required property var modelData
                  width: column.width
                  text: Model.diskLabel(modelData)
                  bordered: true
                  selected: svc.selectedDisk === modelData.path
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  leftAlign: true
                  onClicked: {
                    svc.selectedDisk = modelData.path
                    svc.wipeConfirmed = false
                  }
                }
              }
              Toggle {
                width: parent.width
                visible: svc.selectedDisk !== ""
                label: "I understand this will erase that disk"
                description: svc.selectedDiskLabel
                checked: svc.wipeConfirmed
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.wipeConfirmed = !svc.wipeConfirmed
              }
              Button {
                width: parent.width
                text: "Erase USB and set it up"
                foreground: Color.background
                background: Color.accent
                accent: Color.accent
                enabled: !svc.backupRunning && svc.selectedDisk !== "" && svc.wipeConfirmed
                fontFamily: root.fontFamily
                onClicked: svc.startFirstRun(svc.selectedDisk)
              }
            }
          }

          // —— Settings ——
          Column {
            visible: root.page === "settings"
            width: parent.width
            spacing: Style.space(12)

            Button {
              text: "←  Back"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.page = "home"
            }

            PanelHero {
              width: parent.width
              title: "Settings"
              meta: root.blockedByRestore
                ? svc.version + "  ·  what to leave out of this restore"
                : svc.version + "  ·  skip folders, disks, Pi, erase disk"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              // Nothing here can be acted on until a restored system has its
              // files back, and a control that cannot be pressed is just noise.
              // The restore card on the home page is the way through.
              visible: !root.blockedByRestore
              width: parent.width
              spacing: Style.space(12)
              PanelSectionHeader {
                text: "AUTOMATIC BACKUPS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Toggle {
                width: parent.width
                label: "Back up automatically"
                description: svc.scheduleOn
                  ? "Skips quietly when the backup disk isn’t reachable or the battery is under 20%."
                  : (svc.hasCapsule
                    ? "Asks for the backup disk password once, so backups can run while you’re away."
                    : "Set up a backup disk first.")
                checked: svc.scheduleOn
                enabled: svc.hasCapsule || svc.scheduleOn
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  if (svc.scheduleOn) svc.setSchedule("enabled", "false")
                  else svc.enableSchedule()
                }
              }
              ButtonGroup {
                visible: svc.scheduleOn
                options: [
                  { value: "hourly", label: "Hourly" },
                  { value: "daily", label: "Daily" },
                  { value: "weekly", label: "Weekly" }
                ]
                value: svc.schedule.every
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function (v) { svc.setSchedule("every", v) }
              }
              Toggle {
                width: parent.width
                label: "Smart thinning"
                description: svc.schedule.retention === "smart"
                  ? "Recommended. Keeps every backup from the last day, one a day for a month, then one a week. Deletes the oldest when the disk is nearly full."
                  : "Never deletes restore points. Warns you when the backup disk is nearly full."
                checked: svc.schedule.retention === "smart"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.setSchedule("retention", checked ? "keep" : "smart")
              }

              PanelSeparator { foreground: root.foreground }
            }
            PanelSectionHeader {
              text: "QUICK SKIPS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              visible: root.blockedByRestore
              width: parent.width
              text: "Tick anything you don't want brought back right now. It stays on the "
                + "backup, and this restore point is kept until you come for it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Repeater {
              model: root.quickSkips
              delegate: Toggle {
                required property var modelData
                width: parent.width
                label: modelData.label
                description: modelData.note
                checked: root.quickSkipOn(modelData)
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  var on = root.quickSkipOn(modelData)
                  var paths = root.quickSkipPaths(modelData)
                  for (var i = 0; i < paths.length; i++) {
                    if (root.blockedByRestore) {
                      if (on) svc.removeRestoreSkip(paths[i])
                      else svc.addRestoreSkip(paths[i])
                    } else {
                      if (on) svc.removeSkip(paths[i])
                      else svc.addSkip(paths[i])
                    }
                  }
                }
              }
            }

            PanelSectionHeader {
              text: root.blockedByRestore ? "LEAVE OUT OF THE RESTORE" : "SKIP"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              visible: root.customSkipCount === 0
              width: parent.width
              text: root.blockedByRestore ? "Nothing left out — everything comes back." : "Nothing skipped yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: parent.width
              text: root.blockedByRestore
                ? "Use this for anything too big for this disk. Folder and File open the "
                  + "backup's own copy, so you pick from what is actually waiting there."
                : "Left off every backup. Use this for anything large you don’t need on the USB."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Repeater {
              model: root.blockedByRestore ? svc.restoreSkipModel : svc.skipModel
              delegate: Rectangle {
                required property string path
                visible: !root.isQuickSkip(path)
                width: column.width
                height: visible ? skipTxt.implicitHeight + Style.space(8) : 0
                radius: Style.cornerRadius
                color: "transparent"
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                border.width: 1
                Text {
                  id: skipTxt
                  anchors.left: parent.left
                  anchors.right: skipRm.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  text: path
                  elide: Text.ElideMiddle
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  id: skipRm
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "×"
                  color: root.dim
                  font.pixelSize: Style.font.body
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      var p = path
                      var restoring = root.blockedByRestore
                      Qt.callLater(function () {
                        if (restoring) svc.removeRestoreSkip(p)
                        else svc.removeSkip(p)
                      })
                    }
                  }
                }
              }
            }
            Row {
              spacing: Style.space(8)
              Button {
                text: "+ Folder"
                bordered: true
                // Picking from the restore point means opening it first, which
                // needs the backup disk and a linked laptop.
                enabled: !root.blockedByRestore || (svc.linked && svc.hasCapsule)
                foreground: root.foreground
                fontFamily: root.fontFamily
                tooltipText: root.blockedByRestore
                  ? "Opens the restore point so you can pick from the copy on the backup"
                  : ""
                onClicked: root.blockedByRestore ? svc.pickInRestorePoint(false) : svc.pickFolder()
              }
              Button {
                text: "+ File"
                bordered: true
                // Picking from the restore point means opening it first, which
                // needs the backup disk and a linked laptop.
                enabled: !root.blockedByRestore || (svc.linked && svc.hasCapsule)
                foreground: root.foreground
                fontFamily: root.fontFamily
                tooltipText: root.blockedByRestore
                  ? "Opens the restore point so you can pick from the copy on the backup"
                  : ""
                onClicked: root.blockedByRestore ? svc.pickInRestorePoint(true) : svc.pickFile()
              }
            }

            // Picking from the restore point has to open it first, which takes
            // a moment and can fail. Both belong here rather than at the top of
            // the panel: from down here a press that says nothing looks broken.
            Text {
              readonly property bool opening: svc.browseMode === "pick" && svc.browsePhase === "opening"
              visible: svc.pickError !== "" || opening
              width: parent.width
              text: svc.pickError !== "" ? svc.pickError : "Opening the restore point…"
              color: svc.pickError !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Toggle {
              visible: !root.blockedByRestore
              width: parent.width
              label: "Show all disks"
              description: "Includes internal drives. Easy to wipe the computer’s own disk."
              checked: svc.showAllDisks
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: svc.showAllDisks = !svc.showAllDisks
            }

            // Not part of setting up: moving the disk to a Pi only makes
            // sense once this laptop has made a backup on it, so the whole
            // section stays out of the way until there is one (or until a Pi
            // is already paired, so it can still be unpaired).
            Column {
              visible: (svc.snapshotCount > 0 || svc.remote !== null) && !root.blockedByRestore
              width: parent.width
              spacing: Style.space(10)
              PanelSeparator { foreground: root.foreground }
              PanelSectionHeader {
                text: "BACK UP TO A PI"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Text {
                width: parent.width
                text: svc.remote !== null
                  ? "Paired with " + svc.remoteHost + ". Backups go there whenever the backup USB isn’t plugged into this laptop."
                  : "Keep the backup USB in an always-on Raspberry Pi and back up over your network or Tailscale."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              TextField {
                id: remoteHostField
                visible: svc.remote === null
                width: parent.width
                placeholderText: "Pi name or IP, e.g. my-pi"
                foreground: root.foreground
                font.family: root.fontFamily
                onAccepted: if (pairBtn.enabled) svc.pairRemote(text)
              }
              Button {
                id: pairBtn
                visible: svc.remote === null
                width: parent.width
                text: svc.capsule !== null ? "Pair with this Pi" : "Plug the backup USB in here to pair"
                bordered: true
                enabled: svc.capsule !== null && remoteHostField.text.trim() !== "" && !svc.backupRunning
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.pairRemote(remoteHostField.text)
              }
              Button {
                visible: svc.remote !== null
                width: parent.width
                text: "Unpair"
                bordered: true
                enabled: !svc.backupRunning
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.forgetRemote()
              }
            }

            // Needs the Pi, something on it to restore, and a linked laptop.
            Column {
              visible: svc.remote !== null && svc.snapshotCount > 0 && svc.linked && !root.blockedByRestore
              width: parent.width
              spacing: Style.space(10)
              PanelSeparator { foreground: root.foreground }
              PanelSectionHeader {
                text: "NETWORK RESCUE STICK"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Text {
                width: parent.width
                text: "A USB (8 GB or bigger) that can restore this laptop from " + svc.remoteHost
                  + " without the backup disk: at home, or anywhere over Tailscale. It opens with the backup disk’s password and can only read backups. Making a new one switches the old one off."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Text {
                visible: root.stickDisks.length === 0
                width: parent.width
                text: "Plug in the USB you want to use."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Repeater {
                model: root.stickDisks
                delegate: Button {
                  required property var modelData
                  width: column.width
                  text: Model.diskLabel(modelData)
                  bordered: true
                  selected: root.stickDisk === modelData.path
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  leftAlign: true
                  onClicked: {
                    root.stickDisk = modelData.path
                    root.stickConfirmed = false
                  }
                }
              }
              Toggle {
                visible: root.stickDisk !== ""
                width: parent.width
                label: "I understand this will erase that USB"
                checked: root.stickConfirmed
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.stickConfirmed = !root.stickConfirmed
              }
              Button {
                visible: root.stickDisk !== ""
                width: parent.width
                text: "Make the rescue stick"
                foreground: Color.background
                background: Color.accent
                accent: Color.accent
                enabled: root.stickConfirmed && !svc.backupRunning
                fontFamily: root.fontFamily
                onClicked: {
                  svc.makeRescueStick(root.stickDisk)
                  root.stickDisk = ""
                  root.stickConfirmed = false
                }
              }
            }

            Column {
              visible: svc.hasCapsule && !root.blockedByRestore
              width: parent.width
              spacing: Style.space(10)
              PanelSeparator { foreground: root.foreground }
              PanelSectionHeader {
                text: "USE A DIFFERENT DISK"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Text {
                width: parent.width
                text: "Set up another USB as the backup disk. The current one isn’t erased: its restore points stay on it, and you can unplug it once the new one is ready."
                  + (svc.remote !== null ? " To keep the new disk on the Pi, pair it again." : "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Text {
                visible: root.otherDisks.length === 0
                width: parent.width
                text: "Plug in the USB you want to use."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Repeater {
                model: root.otherDisks
                delegate: Button {
                  required property var modelData
                  width: column.width
                  text: Model.diskLabel(modelData)
                  bordered: true
                  selected: root.newDisk === modelData.path
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  leftAlign: true
                  onClicked: {
                    root.newDisk = modelData.path
                    root.newDiskConfirmed = false
                  }
                }
              }
              Toggle {
                visible: root.newDisk !== ""
                width: parent.width
                label: "I understand this will erase that disk"
                checked: root.newDiskConfirmed
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.newDiskConfirmed = !root.newDiskConfirmed
              }
              Button {
                visible: root.newDisk !== ""
                width: parent.width
                text: "Erase it and use it from now on"
                foreground: Color.background
                background: Color.accent
                accent: Color.accent
                enabled: root.newDiskConfirmed && !svc.backupRunning
                fontFamily: root.fontFamily
                onClicked: {
                  svc.selectedDisk = root.newDisk
                  svc.wipeConfirmed = true
                  svc.startFirstRun(root.newDisk)
                  root.newDisk = ""
                  root.newDiskConfirmed = false
                }
              }
            }

            Column {
              // Nothing here can be acted on until a restored system has its
              // files back, and a control that cannot be pressed is just noise.
              // The restore card on the home page is the way through.
              visible: !root.blockedByRestore
              width: parent.width
              spacing: Style.space(12)
              PanelSeparator { foreground: root.foreground }
              PanelSectionHeader {
                text: "START OVER"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Text {
                width: parent.width
                text: "Leave this off to keep every copy already on the USB."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Toggle {
                width: parent.width
                label: "Erase this backup disk"
                description: svc.capsule !== null
                  ? "Deletes every restore point, then sets a new encryption password."
                  : (svc.remoteActive
                    ? "The backup USB is on " + svc.remoteHost + ". Plug it in here to erase it."
                    : "No backup USB is set up. Go back and pick the USB on the home page.")
                checked: svc.replaceDisk
                enabled: svc.capsule !== null
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  if (svc.capsule === null) return
                  svc.replaceDisk = !svc.replaceDisk
                  svc.wipeConfirmed = false
                  if (svc.capsule) svc.selectedDisk = svc.capsule.path
                }
              }
              Column {
                visible: svc.replaceDisk
                width: parent.width
                spacing: Style.space(8)
                Text {
                  width: parent.width
                  text: "This cannot be undone."
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
                Toggle {
                  width: parent.width
                  label: "I understand every backup on this USB will be destroyed"
                  description: svc.capsule ? Model.diskLabel(svc.capsule) : svc.selectedDiskLabel
                  checked: svc.wipeConfirmed
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: svc.wipeConfirmed = !svc.wipeConfirmed
                }
                Button {
                  width: parent.width
                  text: "Erase USB and start over"
                  foreground: root.urgent
                  bordered: true
                  enabled: !svc.backupRunning && svc.wipeConfirmed && svc.selectedDisk !== ""
                  fontFamily: root.fontFamily
                  onClicked: svc.startFirstRun(svc.selectedDisk)
                }
              }
            }
          }
        }
      }
    }
  }
}
