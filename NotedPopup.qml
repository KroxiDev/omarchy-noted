import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons as Commons
import "Session.js" as Session

// KeyboardPanel-style fallback: full-screen dismissal surfaces consume the
// outside click. Do not replay input into arbitrary applications. Position,
// focus priming follow Omarchy's Ui/KeyboardPanel.qml. The bar strip is
// excluded from the input mask so actual bar buttons receive their own clicks.
PanelWindow {
    id: popup
    required property Item anchorItem
    required property var bar
    required property var owner
    required property Item focusTarget
    property bool open: false
    property int cardWidth: 360
    property int cardHeight: 360
    property bool primed: false
    default property alias contents: holder.data
    readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
    readonly property string edge: bar ? bar.position : "bottom"
    readonly property int gap: Commons.Style.gapsOut
    readonly property int screenW: screen ? screen.width : 1920
    readonly property int screenH: screen ? screen.height : 1080
    readonly property point buttonPoint: {
        watcher.transform
        return anchorWindow ? anchorItem.mapToItem(anchorWindow.contentItem, 0, 0) : Qt.point(0, 0)
    }
    readonly property int barW: anchorWindow ? anchorWindow.width : 0
    readonly property int barH: anchorWindow ? anchorWindow.height : 0
    readonly property real buttonX: buttonPoint.x + anchorItem.width / 2
    readonly property real buttonY: buttonPoint.y + anchorItem.height / 2
    readonly property int fittedWidth: Math.min(cardWidth, screenW - 2 * gap - ((edge === "left" || edge === "right") ? barW : 0))
    readonly property int fittedHeight: Math.min(cardHeight, screenH - 2 * gap - ((edge === "top" || edge === "bottom") ? barH : 0))
    readonly property int cardX: Math.round(Math.max(gap, Math.min(screenW - fittedWidth - gap,
        edge === "left" ? barW + gap : edge === "right" ? screenW - barW - fittedWidth - gap : buttonX - fittedWidth / 2)))
    readonly property int cardY: Math.round(Math.max(gap, Math.min(screenH - fittedHeight - gap,
        edge === "top" ? barH + gap : edge === "bottom" ? screenH - barH - fittedHeight - gap : buttonY - fittedHeight / 2)))
    screen: anchorWindow ? anchorWindow.screen : null
    visible: open || card.opacity > 0
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    margins { left: 0; right: 0; top: 0; bottom: 0 }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "krox.noted"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: open ? (primed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive) : WlrKeyboardFocus.None
    mask: Region {
        x: popup.edge === "left" ? popup.barW : 0
        y: popup.edge === "top" ? popup.barH : 0
        width: popup.open ? popup.screenW - ((popup.edge === "left" || popup.edge === "right") ? popup.barW : 0) : 0
        height: popup.open ? popup.screenH - ((popup.edge === "top" || popup.edge === "bottom") ? popup.barH : 0) : 0
    }
    TransformWatcher { id: watcher; a: popup.anchorWindow ? popup.anchorWindow.contentItem : null; b: popup.anchorItem }
    function prime() {
        if (!open || !backingWindowVisible) return
        primeTimer.restart()
        Qt.callLater(function() { if (popup.open && popup.focusTarget) popup.focusTarget.forceActiveFocus() })
    }
    onBackingWindowVisibleChanged: prime()
    onOpenChanged: {
        primed = false
        if (open) {
            if (bar) bar.requestPopout(owner)
            prime()
        } else {
            primeTimer.stop()
            if (bar && bar.activePopout === owner) bar.releasePopout(owner)
        }
    }
    Timer { id: primeTimer; interval: 75; onTriggered: popup.primed = true }
    MouseArea {
        anchors.fill: parent
        enabled: popup.open
        acceptedButtons: Qt.AllButtons
        onClicked: popup.owner.close()
    }

    Variants {
        model: popup.open ? Quickshell.screens : []
        delegate: Component {
            PanelWindow {
                required property var modelData
                readonly property var otherBar: Session.barOnScreen(modelData.name)
                screen: modelData
                visible: popup.visible && popup.open && !!popup.screen && modelData.name !== popup.screen.name
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                anchors { top: true; bottom: true; left: true; right: true }
                WlrLayershell.namespace: "krox.noted-dismiss"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                mask: Region {
                    x: otherBar && otherBar.edge === "left" ? otherBar.width : 0
                    y: otherBar && otherBar.edge === "top" ? otherBar.height : 0
                    width: modelData.width - (otherBar && (otherBar.edge === "left" || otherBar.edge === "right") ? otherBar.width : 0)
                    height: modelData.height - (otherBar && (otherBar.edge === "top" || otherBar.edge === "bottom") ? otherBar.height : 0)
                }
                MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onPressed: popup.owner.close() }
            }
        }
    }
    Rectangle {
        id: card
        x: popup.cardX; y: popup.cardY
        width: popup.fittedWidth; height: popup.fittedHeight
        color: Commons.Color.popups.background
        border.color: Commons.Color.popups.border
        border.width: Math.max(1, Commons.Style.space(2))
        radius: Commons.Style.cornerRadius
        opacity: popup.open ? 1 : 0
        property real progress: popup.open ? 1 : 0.12
        transform: Scale {
            origin.x: popup.edge === "left" ? 0 : popup.edge === "right" ? card.width : popup.buttonX - popup.cardX
            origin.y: popup.edge === "bottom" ? card.height : popup.edge === "top" ? 0 : popup.buttonY - popup.cardY
            xScale: card.progress; yScale: card.progress
        }
        Behavior on progress { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
        Item { id: holder; anchors.fill: parent; anchors.margins: 16; clip: true }
    }
    Behavior on cardWidth { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Behavior on cardHeight { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
}
