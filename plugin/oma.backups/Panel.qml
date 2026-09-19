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
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  property string page: "home"
  property bool showAllSnaps: false
  readonly property var quickSkips: [
    { label: "Downloads", paths: [svc.home + "/Downloads"], note: "" },
    { label: "Trash", paths: ["**/.local/share/Trash", ".Trash"], note: "Recommended" },
    { label: "Caches", paths: [".cache"], note: "Recommended" },
    { label: "Thumbnails & system clutter", paths: [".thumbnails", "lost+found"], note: "Recommended" }
  ]

  function quickSkipOn(paths) {
    for (var i = 0; i < paths.length; i++) if (!svc.hasSkip(paths[i])) return false
    return true
  }

  function isQuickSkip(path) {
    for (var i = 0; i < quickSkips.length; i++)
      if (quickSkips[i].paths.indexOf(path) !== -1) return true
    return false
  }

  // "Use a different disk": every eligible disk except the current backup disk.
  property string newDisk: ""
  property bool newDiskConfirmed: false
  readonly property var otherDisks: {
    var out = []
    var cur = svc.capsule ? svc.capsule.path : ""
    for (var i = 0; i < svc.disks.length; i++)
      if (svc.disks[i].path !== cur) out.push(svc.disks[i])
    return out
  }

  readonly property int customSkipCount: {
    var n = 0
    for (var i = 0; i < svc.skipCount; i++) if (!isQuickSkip(svc.skipModel.get(i).path)) n++
    return n
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  property real spin: 0

  onOpenedChanged: {
    if (opened) {
      svc.refresh()
      Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    } else {
      page = "home"
      showAllSnaps = false
      newDisk = ""
      newDiskConfirmed = false
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
      ? ("OmaBackups (beta) — " + Model.phaseLabel(svc.progressPhase) + " " + svc.progressPercent + "%")
      : (svc.hasCapsule ? "OmaBackups (beta)" : "OmaBackups (beta) — set up a disk")
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
          if (svc.hasCapsule && !svc.backupRunning) svc.startBackup()
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
                  ? (Model.phaseLabel(svc.progressPhase) + "  " + svc.progressPercent + "%")
                  : (svc.hasCapsule ? (svc.lastSnapshot ? ("Last copy  " + svc.lastSnapshot) : "Ready  ·  beta 0.9.1") : "beta 0.9.1  ·  no backup disk yet")
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
                text: Model.phaseLabel(svc.progressPhase) + "  " + svc.progressPercent + "%"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Rectangle {
                width: parent.width
                height: 8
                radius: 4
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                Rectangle {
                  width: Math.max(8, parent.width * Math.min(100, Math.max(0, svc.progressPercent)) / 100)
                  height: parent.height
                  radius: 4
                  color: Color.accent
                }
              }
              Text {
                visible: svc.progressSpeed !== "" || svc.progressEta !== ""
                width: parent.width
                text: [svc.progressSpeed, svc.progressEta ? ("ETA " + svc.progressEta) : ""].filter(function (s) { return s && s.length }).join("   ")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Button {
              width: parent.width
              visible: svc.hasCapsule && !svc.backupRunning && !svc.launchedBackup
              text: svc.backupIncomplete ? "Resume backup" : "Backup now"
              foreground: Color.background
              background: Color.accent
              accent: Color.accent
              fontFamily: root.fontFamily
              onClicked: svc.startBackup()
            }
            Text {
              visible: svc.nextBackupText !== "" && !svc.backupRunning && !svc.launchedBackup
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: svc.nextBackupText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Button {
              width: parent.width
              visible: svc.backupRunning || svc.launchedBackup
              text: "Stop backup"
              foreground: root.urgent
              bordered: true
              fontFamily: root.fontFamily
              onClicked: svc.stopBackup()
            }

            Rectangle {
              visible: svc.browseTs !== ""
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
                  : "Browsing " + Model.prettyStamp(svc.browseTs) + "  ·  read-only"
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
                    : "Open a date to browse that copy.")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Repeater {
                model: svc.snapModel
                delegate: Rectangle {
                  required property int index
                  required property string whenText
                  required property string snapId
                  required property string sizeText
                  visible: root.showAllSnaps || index < 5
                  width: column.width
                  height: visible ? (rpTxt.implicitHeight + Style.space(10)) : 0
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                  border.width: 1
                  Text {
                    id: rpTxt
                    anchors.left: parent.left
                    anchors.right: rpSize.visible ? rpSize.left : parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(6)
                    text: whenText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    id: rpSize
                    visible: sizeText !== ""
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.rightMargin: Style.space(8)
                    text: sizeText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: svc.linked || !svc.remoteActive
                    cursorShape: Qt.PointingHandCursor
                    onClicked: svc.openSnapshot(snapId)
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
                text: "Erase USB and start first backup"
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
              meta: "beta 0.9.1  ·  skip folders, disks, Pi, erase disk"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

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
            PanelSectionHeader {
              text: "QUICK SKIPS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Repeater {
              model: root.quickSkips
              delegate: Toggle {
                required property var modelData
                width: parent.width
                label: modelData.label
                description: modelData.note
                checked: root.quickSkipOn(modelData.paths)
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  var on = root.quickSkipOn(modelData.paths)
                  for (var i = 0; i < modelData.paths.length; i++) {
                    if (on) svc.removeSkip(modelData.paths[i])
                    else svc.addSkip(modelData.paths[i])
                  }
                }
              }
            }

            PanelSectionHeader {
              text: "SKIP"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              visible: root.customSkipCount === 0
              width: parent.width
              text: "Nothing skipped yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: parent.width
              text: "Left off every backup. Use this for anything large you don’t need on the USB."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Repeater {
              model: svc.skipModel
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
                      Qt.callLater(function () { svc.removeSkip(p) })
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
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.pickFolder()
              }
              Button {
                text: "+ File"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.pickFile()
              }
            }

            Toggle {
              width: parent.width
              label: "Show all disks"
              description: "Includes internal drives. Easy to wipe the computer’s own disk."
              checked: svc.showAllDisks
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: svc.showAllDisks = !svc.showAllDisks
            }

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

            Column {
              visible: svc.hasCapsule
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
                text: "Erase it and back up to it from now on"
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
