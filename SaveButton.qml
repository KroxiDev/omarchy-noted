import QtQuick
import QtQuick.Controls

ActionButton {
    id: control
    required property var strings
    objectName: "notedSaveButton"
    signal destinationRequested()
    text: "\u{F0193}"
    Accessible.name: strings.t("save_note")
    ToolTip.visible: hovered || rightClick.containsMouse
    ToolTip.text: strings.t("save_tooltip")
    // Only intercept right clicks; left clicks retain Button's accessibility,
    // pressed/hover feedback and normal clicked signal.
    MouseArea {
        id: rightClick
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: control.destinationRequested()
    }
}
