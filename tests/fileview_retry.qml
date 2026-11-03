import QtQuick
import Quickshell
import Quickshell.Io

// Isolated regression for FileView's cached failed-write behavior.
// Run through test_fileview.sh, never against the user's notes directory.
ShellRoot {
    id: root
    readonly property string fixture: Quickshell.env("NOTED_TEST_FIXTURE")
    property bool writeFailed: false
    property bool writeSucceeded: false
    property bool dirty: true
    property bool exerciseComplete: false

    function expect(condition, label) {
        console.log((condition ? "NOTED_TEST_PASS " : "NOTED_TEST_FAIL ") + label)
        return condition
    }

    function flush(text) {
        writeFailed = false
        writeSucceeded = false
        // Keep this cache invalidation and explicit success check aligned with
        // Panel.qml: neither waitForJob nor absence of saveFailed proves a save.
        var path = primary.path
        primary.path = ""
        primary.path = path
        primary.setText(text)
        primary.waitForJob()
        if (writeFailed || !writeSucceeded) return false
        dirty = false
        return true
    }

    FileView {
        id: primary
        path: root.fixture + "/notes/note.md"
        atomicWrites: true
        blockWrites: true
        preload: false
        printErrors: false
        onSaveFailed: root.writeFailed = true
        onSaved: root.writeSucceeded = true
    }

    Timer {
        interval: 100
        running: true
        onTriggered: {
            var first = root.flush("NEW")
            root.expect(!first && root.writeFailed && !root.writeSucceeded && root.dirty,
                        "first unwritable save retains dirty buffer")
            var retry = root.flush("NEW")
            root.expect(!retry && root.writeFailed && !root.writeSucceeded && root.dirty,
                        "identical unwritable retry retains dirty buffer")
            makeWritable.running = true
        }
    }

    Process {
        id: makeWritable
        command: ["/usr/bin/chmod", "755", root.fixture + "/notes"]
        onExited: function(code) {
            if (!root.expect(code === 0, "restore fixture permissions")) {
                Qt.quit()
                return
            }
            var recovered = root.flush("NEW")
            root.expect(recovered && !root.writeFailed && root.writeSucceeded && !root.dirty,
                        "identical text saves after permission recovery")
            root.dirty = true
            var repeated = root.flush("NEW")
            root.expect(repeated && root.writeSucceeded && !root.dirty,
                        "identical successful save emits saved again")
            root.dirty = true
            root.exerciseComplete = true
            Qt.quit()
        }
    }

    Timer {
        interval: 5000
        running: true
        onTriggered: {
            root.expect(false, "watchdog timeout")
            Qt.quit()
        }
    }

    Component.onDestruction: {
        if (exerciseComplete) {
            var saved = flush("DESTRUCTOR")
            expect(saved && writeSucceeded && !writeFailed && !dirty,
                   "destruction flush completes synchronously")
        }
    }
}
