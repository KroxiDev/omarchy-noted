import QtQuick
import QtQuick.Controls
import qs.Commons as Commons
Item {
    id: root
    required property var strings
    required property string family
    property alias text: input.text
    property alias input: input
    property alias scrollY: flick.contentY
    signal edited()
    signal closeRequested()
    signal saveAsRequested()
    signal saveRequested()
    function replaceText(value, preserve) {
        var cursor = input.cursorPosition
        var scroll = flick.contentY
        input.text = value
        input.cursorPosition = preserve ? Math.min(cursor, value.length) : 0
        flick.contentY = preserve ? Math.max(0, Math.min(scroll, flick.contentHeight - flick.height)) : 0
    }
    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: Math.max(height, input.contentHeight + input.topPadding + input.bottomPadding)
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { }
        TextArea.flickable: TextArea {
            id: input
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            persistentSelection: true
            color: Commons.Color.foreground
            selectionColor: Commons.Color.accent
            selectedTextColor: Commons.Color.background
            font.family: root.family
            font.pixelSize: 16
            topPadding: 20; bottomPadding: 36; leftPadding: 24; rightPadding: 24
            placeholderText: strings.t("write_placeholder")
            placeholderTextColor: Commons.Color.muted
            background: null
            onTextChanged: root.edited()
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { event.accepted = true; root.closeRequested() }
                else if (event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier)) {
                    event.accepted = true; root.saveAsRequested()
                } else if (event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier)) {
                    event.accepted = true; root.saveRequested()
                } else if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
                    event.accepted = true; input.paste()
                }
            }
        }
    }
}
