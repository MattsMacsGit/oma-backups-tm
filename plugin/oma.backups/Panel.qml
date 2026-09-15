import QtQuick
import QtQuick.Layouts
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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf0a0"
    textRotation: svc.backupRunning ? root.spin : 0
    foreground: svc.backupRunning ? root.urgent : root.foreground
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

            Column {
              visible: svc.hasCapsule
              width: parent.width
              spacing: Style.space(10)

              Button {
                width: parent.width
                visible: !svc.backupRunning && !svc.launchedBackup
                text: "Backup now"
                foreground: Color.background
                background: Color.accent
                accent: Color.accent
                fontFamily: root.fontFamily
                onClicked: svc.startBackup()
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

              PanelSectionHeader {
                text: svc.snapshotCount ? ("RESTORE POINTS  ·  " + svc.snapshotCount) : "RESTORE POINTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Text {
                width: parent.width
                text: svc.snapshotCount === 0
                  ? "No dated copies yet. After a backup they appear here."
                  : "Open a date to browse that copy."
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
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    text: whenText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  MouseArea {
                    anchors.fill: parent
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
              visible: !svc.hasCapsule
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
              meta: "beta 0.9.1  ·  skip folders, terminal, erase disk"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            PanelSectionHeader {
              text: "SKIP"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              visible: svc.skipCount === 0
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
                width: column.width
                height: skipTxt.implicitHeight + Style.space(8)
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
              label: "Show backup terminal"
              description: "Shows sudo and the encryption password prompt."
              checked: svc.showTerminal
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: svc.showTerminal = !svc.showTerminal
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
              description: svc.hasCapsule
                ? "Deletes every restore point, then sets a new encryption password."
                : "No backup USB is set up. Go back and pick the USB on the home page."
              checked: svc.replaceDisk
              enabled: svc.hasCapsule
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: {
                if (!svc.hasCapsule) return
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
