import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Prayer times popup. Reads everything through `hostWidget` (injected by
// BarWidget.injectPanel) so there is exactly one copy of the parsed status.
Panel {
  id: root
  moduleName: "prayer.times"
  ipcTarget: ""
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // the popout coordinator must compare against the host widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var prayerData: hostWidget ? hostWidget.prayerData : null
  readonly property bool ready: hostWidget ? hostWidget.ready : false
  readonly property string countdown: hostWidget ? hostWidget.countdown : ""
  readonly property string nextName: ready ? prayerData.next.name : ""

  function open() {
    root.controller.show()
    if (hostWidget) hostWidget.refresh()
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        // ---- Header: where and when.
        Column {
          width: parent.width
          spacing: Style.space(2)

          Text {
            text: root.ready
              ? (root.prayerData.country ? root.prayerData.city + ", " + root.prayerData.country
                                   : root.prayerData.city)
              : "Prayer times"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            visible: root.ready
            text: root.ready
              ? [root.prayerData.date, root.prayerData.hijri].filter(function(v) { return !!v }).join(" · ")
              : ""
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Error state, when the producer could not be read.
        Text {
          visible: !root.ready
          width: parent.width
          wrapMode: Text.WordWrap
          text: hostWidget && hostWidget.errorText !== ""
            ? hostWidget.errorText
            : "No prayer times available yet."
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        PanelSeparator { visible: root.ready; width: parent.width }

        // ---- The five prayers, next one highlighted.
        Column {
          visible: root.ready
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: root.ready ? root.prayerData.prayers : []

            Item {
              required property var modelData
              readonly property bool isNext: modelData.name === root.nextName

              width: column.width
              height: Style.space(24)

              Rectangle {
                anchors.fill: parent
                radius: Style.space(6)
                color: parent.isNext ? Color.popups.border : "transparent"
                opacity: parent.isNext ? 0.18 : 0
              }

              Rectangle {
                id: dot
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(5)
                height: width
                radius: width / 2
                color: parent.isNext ? Color.accent : Color.muted
              }

              Text {
                anchors.left: dot.right
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.pretty
                color: parent.isNext ? Color.accent : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: parent.isNext
              }

              Text {
                id: timeLabel
                anchors.right: tagLabel.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.time
                color: parent.isNext ? Color.popups.text : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                id: tagLabel
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                width: Style.space(52)
                text: Model.rowTag(modelData, root.nextName, root.countdown)
                color: parent.isNext ? Color.accent : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        PanelSeparator { visible: root.ready; width: parent.width }

        // ---- Footer: qibla on the left, method and source on the right.
        Item {
          visible: root.ready
          width: parent.width
          height: Style.space(16)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.ready ? Model.qiblaLabel(root.prayerData.qibla) : ""
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.ready ? Model.sourceLabel(root.prayerData.method, root.prayerData.source) : ""
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Actions.
        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: root.prayerData && root.prayerData.muted ? "Muted today" : "Mute today"
            bordered: true
            fontSize: Style.font.bodySmall
            enabled: root.ready
            onClicked: {
              if (root.hostWidget) root.hostWidget.muteToday()
            }
          }

          Button {
            text: "Stop adhan"
            bordered: true
            fontSize: Style.font.bodySmall
            foreground: Color.urgent
            onClicked: {
              if (root.hostWidget) root.hostWidget.stopAdhan()
              root.close()
            }
          }
        }
      }
    }
  }
}
