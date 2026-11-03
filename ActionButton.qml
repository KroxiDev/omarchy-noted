import QtQuick
import QtQuick.Controls
import qs.Commons as Commons
Button {
    id: control
    property string family: Commons.Style.font.family
    property bool danger: false
    font.family: family
    font.pixelSize: 13
    focusPolicy: Qt.NoFocus
    padding: 8
    contentItem: Text {
        text: control.text
        textFormat: Text.PlainText
        font: control.font
        color: control.danger ? Commons.Color.urgent : Commons.Color.foreground
        opacity: control.enabled ? 1 : 0.4
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
    background: Rectangle {
        radius: 5
        color: control.down ? Qt.rgba(1,1,1,0.15) : control.hovered ? Qt.rgba(1,1,1,0.08) : "transparent"
    }
}
