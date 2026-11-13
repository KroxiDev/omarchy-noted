import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Session.js" as Session
import qs.Ui
import qs.Commons as Commons

Item {
    id: root
    property var bar: null
    property string moduleName: "krox.noted"
    property var settings: ({})
    readonly property alias editorItem: editor
    readonly property string home: Quickshell.env("HOME")
    property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/noted-store")).replace(/^file:\/\//, ""))
    property string dialogHelper: decodeURIComponent(String(Qt.resolvedUrl("bin/noted-save-dialog")).replace(/^file:\/\//, ""))
    readonly property string family: bar ? bar.fontFamily : Commons.Style.font.family
    property bool ipcReady: false
    property bool ipcOwner: false
    readonly property var barWindow: button.QsWindow.window
    readonly property bool canOwnIpc: ipcReady && visible && width > 0 && height > 0 && button.QsWindow.window !== null
    readonly property string screenName: button.QsWindow.window && button.QsWindow.window.screen ? button.QsWindow.window.screen.name : ""
    readonly property string requestedFolder: String(settings.folder || "")
    property string activeFolder: ""
    onCanOwnIpcChanged: { Session.elect(); initialize() }
    onRequestedFolderChanged: folderDelay.restart()
    onTransitionBusyChanged: if (!transitionBusy) folderDelay.restart()
    onDialogOpenChanged: if (!dialogOpen) folderDelay.restart()
    onDirtyChanged: if (!dirty) folderDelay.restart()
    property bool opened: false
    property bool ready: false
    property bool initialized: false
    property bool transitionBusy: false
    property bool dialogOpen: false
    property string dialogText: ""
    property bool recoverySucceeded: false
    readonly property string recoveryDirectory: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/noted/drafts"
    property string directory: ""
    property var notes: []
    property var undoStack: []
    property string noteId: ""
    property bool persisted: false
    property bool dirty: false
    property bool loading: false
    property bool writing: false
    property bool writeFailed: false
    property bool writeSucceeded: false
    property bool loadFailed: false
    property var notice: ""
    readonly property string message: i18n.message(notice)
    property string armedName: ""
    property var queue: []
    property var currentJob: null
    property bool associated: false
    property bool diskConflict: false
    property string lastDiskText: ""
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function request(data, callback) {
        if (data.folder === undefined) data.folder = activeFolder
        queue.push({data: data, callback: callback})
        pump()
    }
    function pump() {
        if (currentJob || worker.running || queue.length === 0) return
        currentJob = queue.shift()
        worker.stdinEnabled = true
        worker.didStart = false
        worker.running = true
    }
    function result(text) {
        var job = currentJob
        currentJob = null
        var data
        try { data = JSON.parse(text) } catch (e) { data = {ok: false, error: "communication_failed"} }
        if (!data.ok) notice = data.error || "operation_failed"
        if (job && job.callback) job.callback(data)
        Qt.callLater(pump)
    }
    function applyListing(data) {
        if (!data.ok) return
        ready = true
        directory = data.directory
        notes = data.notes
        if (data.warnings && data.warnings.length) notice = data.warnings
    }
    function refresh() { request({op: "list"}, applyListing) }
    function focusContent() {
        Qt.callLater(function() {
            if (opened) (noteId ? editor.input : listKeys).forceActiveFocus()
        })
    }
    function open() {
        if (dialogOpen || transitionBusy || !Session.activate(root)) return
        opened = true
        refresh()
        if (noteId && persisted && !dirty) reloadCurrent()
        focusContent()
    }
    function close() {
        if (dialogOpen || transitionBusy) return
        leave(function() { opened = false })
        // Minimize even after a failed save, but retain the dirty buffer. The
        // dismissal overlays must not lock users out of repairing permissions.
        opened = false
        if (noteId && dirty && editor.text.trim())
            Quickshell.execDetached(["notify-send", "Noted", i18n.t("save_notification")])
    }
    function toggle() { opened ? close() : open() }
    function closeForPopoutSwitch() { close() }
    // Empty buffers never overwrite the last persisted text: trash retains it
    // for undo. A failed write/trash never abandons the editor buffer.
    function leave(done) {
        if (transitionBusy) return
        if (!noteId || editor.text.trim() !== "") {
            if (flush()) done()
            return
        }
        debounce.stop()
        if (!persisted) { resetNote(); done(); return }
        if (!safeToTrashBlank()) { resetNote(); refresh(); done(); return }
        trash(noteId, done)
    }
    function safeToTrashBlank() {
        loadFailed = false
        reader.path = noteId
        reader.reload()
        reader.waitForJob()
        if (loadFailed || !reader.loaded || reader.text() !== lastDiskText) {
            notice = "external_preserved"
            return false
        }
        return true
    }
    function resetNote() {
        loading = true
        noteId = ""
        dirty = false
        persisted = false
        associated = false
        diskConflict = false
        lastDiskText = ""
        primary.path = ""
        editor.replaceText("", false)
        loading = false
        armedName = ""
    }
    function newNote() {
        if (!ready || dialogOpen || transitionBusy || !Session.activate(root)) return
        leave(function() {
            transitionBusy = true
            request({op: "allocate"}, function(data) {
                transitionBusy = false
                if (!data.ok) return
                loading = true
                noteId = data.id
                associated = false
                diskConflict = false
                lastDiskText = ""
                persisted = false
                dirty = false
                editor.replaceText("", false)
                primary.path = data.path
                loading = false
                notice = ""
                opened = true
                focusContent()
            })
        })
    }
    function selectNote(id) {
        if (transitionBusy || dialogOpen || !ready) return
        if (noteId === id) { focusContent(); return }
        leave(function() {
            transitionBusy = true
            request({op: "info", id: id}, function(data) {
                transitionBusy = false
                if (!data.ok) return
                loading = true
                reader.path = data.path
                loadFailed = false
                reader.reload()
                reader.waitForJob()
                var text = reader.text()
                if (loadFailed || !reader.loaded) {
                    notice = "open_failed"
                    loading = false
                    return
                }
                noteId = data.id
                associated = data.associated
                primary.path = data.path
                editor.replaceText(text, false)
                lastDiskText = text
                persisted = true
                dirty = false
                diskConflict = false
                loading = false
                notice = ""
                armedName = ""
                focusContent()
            })
        })
    }
    function showList() {
        if (dialogOpen) return
        leave(function() { resetNote(); refresh(); focusContent() })
    }
    function flush(force) {
        debounce.stop()
        if (!noteId || !dirty || editor.text.trim() === "") return true
        if (persisted && force !== true) {
            // Direct association does not mean overwriting concurrent external
            // edits silently. Compare against the last content seen on disk.
            loadFailed = false
            reader.path = noteId
            reader.reload()
            reader.waitForJob()
            var diskText = reader.text()
            if (loadFailed || !reader.loaded || (diskText !== lastDiskText && diskText !== editor.text)) {
                diskConflict = true
                notice = "external_conflict"
                return false
            }
        }
        writing = true
        writeFailed = false
        writeSucceeded = false
        // FileView caches failed setText too; always invalidate that cache.
        primary.path = ""
        primary.path = noteId
        primary.setText(editor.text)
        primary.waitForJob()
        writing = false
        if (writeFailed || !writeSucceeded) {
            notice = "save_failed"
            return false
        }
        persisted = true
        dirty = false
        diskConflict = false
        lastDiskText = editor.text
        notice = ""
        return true
    }
    function reloadCurrent(discardPending) {
        if (!noteId || !persisted || (dirty && discardPending !== true) || writing || transitionBusy || dialogOpen) return
        loadFailed = false
        reader.path = noteId
        reader.reload()
        reader.waitForJob()
        if (loadFailed || !reader.loaded) {
            diskConflict = true
            notice = "file_unavailable"
            return
        }
        var text = reader.text()
        if (text !== editor.text) {
            loading = true
            editor.replaceText(text, true)
            loading = false
        }
        lastDiskText = text
        dirty = false
        diskConflict = false
        notice = ""
    }
    function confirmTrash(name) {
        if (transitionBusy || dialogOpen) return
        if (armedName !== name) { armedName = name; armTimer.restart(); return }
        armedName = ""
        if (name === noteId && !flush()) return
        if (name === noteId && !persisted) { resetNote(); focusContent(); return }
        trash(name, function() { refresh(); focusContent() })
    }
    function trash(name, done) {
        transitionBusy = true
        request({op: "trash", id: name}, function(data) {
            transitionBusy = false
            if (!data.ok) return
            Session.pushUndo(data.path, activeFolder)
            if (noteId === name) resetNote()
            if (done) done()
            refresh()
        })
    }
    function undoTrash() {
        if (noteId || !undoStack.length || transitionBusy) return
        var stack = undoStack.slice()
        var entry = stack.pop()
        transitionBusy = true
        request({op: "restore", path: entry.path, folder: entry.folder}, function(data) {
            transitionBusy = false
            Session.setUndo(stack)
            refresh()
            focusContent()
        })
    }
    function save() {
        if (!noteId || dialogOpen || transitionBusy) return
        if (!associated) { saveAs(); return }
        // A manual save also validates/retries a missing or changed destination.
        dirty = true
        flush()
        focusContent()
    }
    function saveAs() {
        if (!noteId || dialogOpen || transitionBusy) return
        if (!editor.text.trim()) { notice = "write_first"; return }
        // A chooser must remain available to rescue unsaved text when the
        // current file is read-only, missing, or externally modified.
        flush()
        dialogText = editor.text
        notice = ""
        dialogOpen = true
        opened = false
        dialogDelay.restart()
    }
    function changeDestination(path, snapshot) {
        if (!noteId || transitionBusy) return
        transitionBusy = true
        request({op: "save-as", id: noteId, path: path, text: snapshot === undefined ? editor.text : snapshot}, function(data) {
            transitionBusy = false
            if (data.ok) {
                noteId = data.note.id
                associated = data.note.associated
                primary.path = data.note.path
                persisted = true
                dirty = false
                diskConflict = false
                if (data.trashed) Session.pushUndo(data.trashed, activeFolder)
                reloadCurrent()
                notice = data.warning || ""
                refresh()
            }
            focusContent()
        })
    }
    function titleFor(text) {
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) if (lines[i].trim()) return lines[i].replace(/^\s*#+\s*/, "").trim() || noteId.split("/").pop()
        return noteId.split("/").pop()
    }
    function noteTime(mtime) {
        var date = new Date(mtime * 1000)
        var today = new Date()
        var locale = Qt.locale(i18n.localeCode.replace(/-/g, "_"))
        return date.toDateString() === today.toDateString()
            ? date.toLocaleTimeString(locale, Locale.ShortFormat)
            : date.toLocaleDateString(locale, Locale.ShortFormat)
    }
    function updateFolder() {
        if (!initialized || activeFolder === requestedFolder) return
        if (transitionBusy || dialogOpen || currentJob || queue.length) { folderDelay.restart(); return }
        leave(function() {
            resetNote()
            activeFolder = requestedFolder
            ready = false
            notes = []
            request({op: "init"}, function(data) { applyListing(data); ready = data.ok })
        })
    }
    Strings { id: i18n; setting: String(root.settings.language || "auto") }
    Timer { id: folderDelay; interval: 100; onTriggered: root.updateFolder() }
    function initialize() {
        if (initialized || !canOwnIpc) return
        initialized = true
        activeFolder = requestedFolder
        request({op: "init"}, function(data) { applyListing(data); ready = data.ok })
    }
    Component.onCompleted: { Session.register(root); Qt.callLater(initialize) }
    function saveRecovery() {
        recoverySucceeded = false
        recovery.path = recoveryDirectory + "/recovered-" + Date.now() + "-" + Math.floor(Math.random() * 1000000000) + ".md"
        recovery.setText(editor.text)
        recovery.waitForJob()
        Quickshell.execDetached(["notify-send", "Noted", recoverySucceeded
            ? i18n.t("recovery_ok")
            : i18n.t("recovery_failed")])
    }
    Component.onDestruction: {
        Session.unregister(root)
        if (noteId && persisted && editor.text.trim() === "") {
            if (safeToTrashBlank()) Quickshell.execDetached([helper, "trash-file", noteId, activeFolder])
        } else if (!flush()) saveRecovery()
    }
    FileView {
        id: recovery
        atomicWrites: true
        blockWrites: true
        preload: false
        printErrors: false
        onSaved: root.recoverySucceeded = true
    }

    Timer { interval: 250; running: true; onTriggered: root.ipcReady = true }
    Timer { id: debounce; interval: 300; onTriggered: root.flush() }
    Timer { id: armTimer; interval: 3000; onTriggered: root.armedName = "" }
    Timer { id: externalDelay; interval: 60; onTriggered: root.reloadCurrent() }
    FileView {
        id: primary
        atomicWrites: true
        blockWrites: true
        preload: false
        watchChanges: true
        printErrors: false
        onSaveFailed: root.writeFailed = true
        onSaved: root.writeSucceeded = true
        onFileChanged: if (!root.dirty && !root.writing) externalDelay.restart()
    }
    FileView {
        id: reader
        blockLoading: true
        blockAllReads: true
        printErrors: false
        onLoadFailed: root.loadFailed = true
    }
    Process {
        id: worker
        command: [root.helper]
        property bool didStart: false
        onRunningChanged: {
            if (!running) {
                var job = root.currentJob
                Qt.callLater(function() {
                    if (!worker.running && !worker.didStart && job && root.currentJob === job)
                        root.result(JSON.stringify({ok: false, error: "store_missing"}))
                })
            }
        }
        onStarted: { didStart = true; write(JSON.stringify(root.currentJob.data)); stdinEnabled = false }
        stdout: StdioCollector { id: workerOutput }
        onExited: root.result(workerOutput.text)
    }
    Timer {
        id: dialogDelay
        interval: 210
        onTriggered: {
            dialog.stdinEnabled = true
            dialog.didStart = false
            dialog.running = true
        }
    }
    Process {
        id: dialog
        command: [root.dialogHelper]
        property bool didStart: false
        onStarted: {
            didStart = true
            // Note text must never appear in the process's command-line arguments.
            write(JSON.stringify({title: root.titleFor(root.dialogText), directory: root.directory,
                                  dialog_title: i18n.t("save_dialog_title"), fallback_name: i18n.t("note_name")}))
            stdinEnabled = false
        }
        onRunningChanged: {
            if (!running) Qt.callLater(function() {
                if (!dialog.running && !dialog.didStart && root.dialogOpen) {
                    root.dialogOpen = false
                    root.opened = true
                    root.notice = "dialog_missing"
                    root.focusContent()
                }
            })
        }
        stdout: StdioCollector { id: dialogOutput }
        stderr: StdioCollector { id: dialogError }
        onExited: function(code) {
            var path = dialogOutput.text.replace(/\n$/, "")
            root.dialogOpen = false
            root.opened = true
            if (code === 0 && path) root.changeDestination(path, root.dialogText)
            else {
                var error
                try { error = JSON.parse(dialogError.text) } catch (e) { error = {error: "dialog_missing"} }
                if (!root.dirty) root.reloadCurrent()
                if (error.error !== "cancelled") root.notice = error
                root.focusContent()
            }
        }
    }

    IpcHandler {
        // Anchored center layouts also instantiate a hidden measuring copy.
        // Only a real visible bar button may own IPC, never that placeholder.
        enabled: root.ipcOwner
        target: "krox.noted"
        function open(): void { Session.dispatch("open", Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "") }
        function close(): void { Session.dispatch("close", Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "") }
        function toggle(): void { Session.dispatch("toggle", Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "") }
        function newNote(): void { Session.dispatch("newNote", Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "") }
    }
    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        readonly property real iconExtent: Commons.Style.space(14)
        hasVisualContent: true
        labelVisible: false
        fixedWidth: vertical ? barSize : iconExtent + scaledHorizontalMargin * 2
        fixedHeight: vertical ? iconExtent + scaledVerticalPadding * 2 : barSize
        active: root.opened
        tooltipText: "Noted"
        onPressed: function(code) { code === Qt.RightButton ? root.newNote() : root.toggle() }

        Image {
            id: noteIcon
            anchors.centerIn: parent
            width: button.iconExtent
            height: button.iconExtent
            source: Qt.resolvedUrl("icons/noted.svg")
            sourceSize.width: Math.round(width * Screen.devicePixelRatio)
            sourceSize.height: Math.round(height * Screen.devicePixelRatio)
            fillMode: Image.PreserveAspectFit
            // Sample the SVG as a texture so it follows every bar theme.
            visible: false
            layer.enabled: true
        }
        MultiEffect {
            anchors.fill: noteIcon
            source: noteIcon
            colorization: 1.0
            colorizationColor: button.active && button.useActiveColor ? button.activeColor : button.foreground
            Behavior on colorizationColor {
                enabled: !root.bar || root.bar.foregroundAnimationEnabled
                ColorAnimation { duration: 160 }
            }
        }
    }
    NotedPopup {
        id: popup
        anchorItem: button
        bar: root.bar
        owner: root
        open: root.opened && !root.dialogOpen
        focusTarget: root.noteId ? editor.input : listKeys
        cardWidth: root.noteId ? 640 : 360
        cardHeight: root.noteId ? Math.round(screenH * 0.6) : Math.min(460, Math.max(190, root.notes.length * 64 + 108))
        ColumnLayout {
            anchors.fill: parent
            spacing: 8
            Item {
                id: listKeys
                visible: !root.noteId
                Layout.fillWidth: true
                Layout.fillHeight: true
                focus: true
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) { event.accepted = true; root.close() }
                    else if (event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier)) { event.accepted = true; root.undoTrash() }
                }
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 8
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "Noted"; color: Commons.Color.foreground; font.family: root.family; font.pixelSize: 20; Layout.fillWidth: true }
                        ActionButton { text: "↶"; family: root.family; visible: root.undoStack.length > 0; enabled: !root.transitionBusy; onClicked: root.undoTrash(); ToolTip.visible: hovered; ToolTip.text: i18n.t("undo_delete") }
                        ActionButton { text: "+"; family: root.family; enabled: root.ready && !root.transitionBusy; onClicked: root.newNote(); ToolTip.visible: hovered; ToolTip.text: i18n.t("new_note") }
                    }
                    ListView {
                        id: noteList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: root.notes
                        spacing: 4
                        ScrollBar.vertical: ScrollBar { }
                        delegate: Item {
                            required property var modelData
                            width: noteList.width
                            height: 56
                            Rectangle { anchors.fill: parent; radius: 5; color: rowMouse.containsMouse ? Qt.rgba(1,1,1,0.06) : "transparent" }
                            MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; enabled: !root.transitionBusy; onClicked: root.selectNote(modelData.id) }
                            Column {
                                anchors.left: parent.left; anchors.leftMargin: 8
                                anchors.right: deleteButton.left; anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 5
                                Text { width: parent.width; text: modelData.title; textFormat: Text.PlainText; elide: Text.ElideRight; color: Commons.Color.foreground; font.family: root.family; font.pixelSize: 14 }
                                Text { text: root.noteTime(modelData.mtime); color: Commons.Color.muted; font.family: root.family; font.pixelSize: 11 }
                            }
                            ActionButton {
                                id: deleteButton
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                family: root.family
                                text: root.armedName === modelData.id ? i18n.t("confirm_delete") : "\u{F01B4}"
                                danger: root.armedName === modelData.id
                                enabled: !root.transitionBusy
                                onClicked: root.confirmTrash(modelData.id)
                            }
                        }
                        Text { anchors.centerIn: parent; visible: root.notes.length === 0; text: root.ready ? i18n.t("empty_list") : i18n.t("loading"); color: Commons.Color.muted; font.family: root.family; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.5 }
                    }
                }
            }
            NoteEditor {
                id: editor
                strings: i18n
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.noteId !== ""
                enabled: !root.transitionBusy
                family: root.family
                onEdited: if (!root.loading && root.noteId) { root.dirty = true; debounce.restart() }
                onCloseRequested: root.close()
                onSaveAsRequested: root.saveAs()
                onSaveRequested: root.save()
            }
            ColumnLayout {
                visible: root.noteId !== ""
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    Layout.fillWidth: true
                    ActionButton { text: "←"; family: root.family; enabled: !root.transitionBusy; onClicked: root.showList(); ToolTip.visible: hovered; ToolTip.text: i18n.t("back_to_list") }
                    Text {
                        Layout.fillWidth: true
                        text: root.associated ? root.noteId.replace(root.home + "/", "~/") : i18n.t("draft_saved")
                        textFormat: Text.PlainText
                        elide: Text.ElideMiddle
                        color: Commons.Color.muted
                        font.family: root.family
                        font.pixelSize: 11
                    }
                    SaveButton { strings: i18n; family: root.family; enabled: !root.transitionBusy; onClicked: root.save(); onDestinationRequested: root.saveAs() }
                    ActionButton { text: root.armedName === root.noteId ? i18n.t("confirm_delete") : "\u{F01B4}"; family: root.family; danger: root.armedName === root.noteId; enabled: !root.transitionBusy; onClicked: root.confirmTrash(root.noteId) }
                }
                RowLayout {
                    visible: root.diskConflict
                    Layout.fillWidth: true
                    Text { Layout.fillWidth: true; text: i18n.t("resolve_conflict"); wrapMode: Text.WordWrap; color: Commons.Color.urgent; font.family: root.family; font.pixelSize: 11 }
                    ActionButton { text: i18n.t("overwrite"); family: root.family; onClicked: { root.dirty = true; root.flush(true) } }
                    ActionButton { text: i18n.t("reload"); family: root.family; onClicked: root.reloadCurrent(true); ToolTip.visible: hovered; ToolTip.text: i18n.t("discard_reload") }
                }
            }
            Text {
                Layout.fillWidth: true
                visible: root.message !== ""
                text: root.message
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Commons.Color.urgent
                font.family: root.family
                font.pixelSize: 12
            }
        }
    }
}
