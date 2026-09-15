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
  readonly property color barIconColor: svc.backupRunning ? urgent : (svc.hasCapsule ? foreground : dim)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  property real spin: 0

  onOpenedChanged: if (opened) {
    svc.refresh()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Service { id: svc }

  component SkipList: Column {
    spacing: Style.space(6)
    Text {
      text: "Skip these folders and files"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      visible: svc.skipModel.count === 0
      width: parent.width
      text: "Nothing skipped — the whole system and home will be copied. Add any folder or file."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
    Repeater {
      model: svc.skipModel
      delegate: Rectangle {
        required property string path
        width: parent ? parent.width : 0
        height: skipTxt.implicitHeight + Style.space(8)
        radius: 6
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
      Rectangle {
        height: addFolderTxt.implicitHeight + Style.space(10)
        width: addFolderTxt.implicitWidth + Style.space(16)
        radius: 6
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
        border.width: 1
        color: "transparent"
        Text {
          id: addFolderTxt
          anchors.centerIn: parent
          text: "+ Folder"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: svc.pickFolder()
        }
      }
      Rectangle {
        height: addFileTxt.implicitHeight + Style.space(10)
        width: addFileTxt.implicitWidth + Style.space(16)
        radius: 6
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
        border.width: 1
        color: "transparent"
        Text {
          id: addFileTxt
          anchors.centerIn: parent
          text: "+ File"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: svc.pickFile()
        }
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { svc.refresh(); return "ok" }
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
    bar: root.bar
    text: "\uf0a0"
    textRotation: svc.backupRunning ? root.spin : 0
    foreground: svc.backupRunning ? root.urgent : root.foreground
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: svc.backupRunning
      ? ("OmaBackups — " + (svc.progressPhase || "backing up") + " " + svc.progressPercent + "%  ETA " + (svc.progressEta || "?"))
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
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: {}

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

          PanelHero {
            width: parent.width
            title: "OmaBackups"
            meta: svc.backupRunning ? svc.statusLine : (svc.hasCapsule ? (svc.lastSnapshot || "Ready") : "No backup disk yet")
            foreground: root.foreground
            fontFamily: root.fontFamily
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
            visible: svc.backupRunning || (svc.progressPhase !== "" && svc.progressPhase !== "idle")
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width
              text: (svc.progressPhase || "working") + (svc.progressPercent ? ("  " + svc.progressPercent + "%") : "")
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

          Text {
            width: parent.width
            text: svc.hasCapsule ? "Backup disk is set. New backups and file copies happen here. Full restore: boot this USB." : "Pick a disk. This will erase it and run the first backup (a terminal will ask for sudo and a LUKS passphrase)."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          SkipList { width: parent.width }

          // Setup: disk picker
          Column {
            visible: !svc.hasCapsule
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "Disk"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: svc.disks
              delegate: Rectangle {
                required property var modelData
                width: column.width
                height: diskTxt.implicitHeight + Style.space(10)
                radius: 6
                color: svc.selectedDisk === modelData.path ? (root.bar ? Style.selectedFillFor(root.foreground, Color.accent) : "#333") : "transparent"
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                border.width: 1
                Text {
                  id: diskTxt
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: Style.space(8)
                  text: Model.diskLabel(modelData)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: svc.selectedDisk = modelData.path
                }
              }
            }

            Rectangle {
              width: parent.width
              height: setupBtn.implicitHeight + Style.space(12)
              radius: 6
              color: Color.accent
              Text {
                id: setupBtn
                anchors.centerIn: parent
                text: svc.backupRunning ? "Working…" : "Erase disk & first backup"
                color: Color.background
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                enabled: !svc.backupRunning && svc.selectedDisk !== ""
                onClicked: svc.startFirstRun(svc.selectedDisk)
              }
            }
          }

          // Ready: skip list still editable, then backup now + snapshots
          Column {
            visible: svc.hasCapsule
            width: parent.width
            spacing: Style.space(8)

            Rectangle {
              width: parent.width
              height: bakBtn.implicitHeight + Style.space(12)
              radius: 6
              color: Color.accent
              Text {
                id: bakBtn
                anchors.centerIn: parent
                text: svc.backupRunning ? "Backup running…" : "Backup now"
                color: Color.background
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                enabled: !svc.backupRunning
                onClicked: svc.startBackup()
              }
            }

            Text {
              visible: svc.snapshots.length > 0
              text: "Restore points — click to open home in the file manager"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              width: parent.width
            }

            Repeater {
              model: svc.snapshots
              delegate: Rectangle {
                required property var modelData
                width: column.width
                height: snapTxt.implicitHeight + Style.space(10)
                radius: 6
                color: "transparent"
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                border.width: 1
                Text {
                  id: snapTxt
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: Style.space(8)
                  text: modelData.timestamp
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: svc.openSnapshot(modelData.timestamp)
                }
              }
            }
          }
        }
      }
    }
  }
}
