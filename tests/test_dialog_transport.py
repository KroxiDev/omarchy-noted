"""Exercise Panel.qml's real chooser process against an isolated fake portal."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DialogTransportTests(unittest.TestCase):
    def test_private_transport_and_repeated_open(self):
        # Like the FileView regression, this needs Quickshell but no desktop.
        result = subprocess.run(['dbus-run-session', '--', sys.executable, __file__, '--portal'],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS: private title, snapshot, cancel, save, and repeated open', result.stdout)


def run_portal_test():
    from gi.repository import Gio, GLib

    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                  'RequestName', GLib.Variant('(su)', ('org.freedesktop.portal.Desktop', 0)),
                  GLib.VariantType.new('(u)'), Gio.DBusCallFlags.NONE, 1000, None)
    info = Gio.DBusNodeInfo.new_for_xml('''<node>
      <interface name="org.freedesktop.portal.FileChooser"><method name="SaveFile">
        <arg type="s" direction="in"/><arg type="s" direction="in"/>
        <arg type="a{sv}" direction="in"/><arg type="o" direction="out"/>
      </method></interface></node>''')
    loop = GLib.MainLoop()
    calls, failures = [], []

    def called(connection, sender, path, interface, method, params, invocation):
        parent, title, options = params.unpack()
        calls.append(options['current_name'])
        number = len(calls)
        pid = bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                            'org.freedesktop.DBus', 'GetConnectionUnixProcessID',
                            GLib.Variant('(s)', (sender,)), GLib.VariantType.new('(u)'),
                            Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
        cmdline = Path(f'/proc/{pid}/cmdline').read_bytes()
        if b'PRIVATE_NOTE' in cmdline:
            failures.append('note title exposed in helper process arguments')
        if options['current_name'] != f'PRIVATE_NOTE_{number}_ñ.md':
            failures.append('suggested name did not use the captured note snapshot')
        if title != 'Guardar nota como' or bytes(options['current_folder']) != os.fsencode(fixture) + b'\0':
            failures.append('chooser directory or translated title changed')
        handle = '/org/freedesktop/portal/desktop/request/' + sender[1:].replace('.', '_') + '/' + options['handle_token']
        invocation.return_value(GLib.Variant('(o)', (handle,)))
        # Cancel the first request, then save on the same QML Process instance.
        code = 1 if number == 1 else 0
        results = {} if code else {'uris': GLib.Variant('as', [Path(fixture, 'saved.md').as_uri()])}
        bus.emit_signal(sender, handle, 'org.freedesktop.portal.Request', 'Response',
                        GLib.Variant('(ua{sv})', (code, results)))

    registration = bus.register_object('/org/freedesktop/portal/desktop', info.interfaces[0], called, None, None)
    with tempfile.TemporaryDirectory(prefix='noted-dialog-test-') as fixture:
        # Take the actual production caller, not a copy of its transport logic.
        panel = (ROOT / 'Panel.qml').read_text()
        chooser = panel[panel.index('    Timer {\n        id: dialogDelay'):panel.index('\n    IpcHandler {')]
        title_function = panel[panel.index('    function titleFor('):panel.index('    function noteTime(')]
        qml = '''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
    id: root
    property string dialogHelper: HELPER
    property string directory: DIRECTORY
    property string noteId: "draft.md"
    property string dialogText: ""
    property bool dialogOpen: false
    property bool opened: false
    property bool dirty: true
    property var notice: ""
    property int attempt: 0
    property int saves: 0
    property string savedText: ""
    property string savedPath: ""
    QtObject { id: editor; property string text: "" }
    QtObject {
        id: i18n
        function t(key) { return key === "save_dialog_title" ? "Guardar nota como" : "Nota" }
    }
    function focusContent() {}
    function reloadCurrent() {}
    function changeDestination(path, snapshot) { saves++; savedPath = path; savedText = snapshot }
    function next() {
        if (attempt === 1 && (saves !== 0 || notice !== "")) {
            console.log("NOTED_TEST_FAIL cancellation must not save or show an error")
            Qt.quit()
            return
        }
        if (attempt === 2) {
            if (saves !== 1 || notice !== "" || savedPath !== directory + "/saved.md" || savedText !== dialogText)
                console.log("NOTED_TEST_FAIL unexpected save result")
            else console.log("NOTED_TEST_DONE")
            Qt.quit()
            return
        }
        attempt++
        dialogText = "\\n# PRIVATE_NOTE_" + attempt + "_ñ\\nBody"
        editor.text = attempt === 1 ? dialogText : "PRIVATE_NOTE_CHANGED_AFTER_SNAPSHOT"
        dialogOpen = true
        dialogDelay.restart()
    }
    onDialogOpenChanged: if (!dialogOpen) Qt.callLater(next)
    Component.onCompleted: next()
TITLE_FUNCTION
CHOOSER
}
'''
        qml = qml.replace('HELPER', json.dumps(str(ROOT / 'bin/noted-save-dialog')))
        qml = qml.replace('DIRECTORY', json.dumps(fixture)).replace('TITLE_FUNCTION', title_function).replace('CHOOSER', chooser)
        shell = Path(fixture, 'shell.qml')
        shell.write_text(qml)
        env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='basic', QT_QUICK_CONTROLS_STYLE='Basic')
        for key in ('DISPLAY', 'WAYLAND_DISPLAY'):
            env.pop(key, None)
        for key in ('HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME'):
            folder = Path(fixture, key)
            folder.mkdir(mode=0o700)
            env[key] = str(folder)
        with Path(fixture, 'quickshell.log').open('w+') as log:
            child = subprocess.Popen(['quickshell', '--no-color', '-p', str(shell)], env=env, stdout=log, stderr=log)

            def finished():
                if child.poll() is None:
                    return GLib.SOURCE_CONTINUE
                loop.quit()
                return GLib.SOURCE_REMOVE

            def expired():
                failures.append('timed out waiting for chooser; stdin may not have been closed or reopened')
                loop.quit()
                return GLib.SOURCE_REMOVE

            GLib.timeout_add(20, finished)
            GLib.timeout_add_seconds(6, expired)
            try:
                loop.run()
            finally:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=2)
                bus.unregister_object(registration)
            log.seek(0)
            output = log.read()
            if child.returncode != 0 or 'NOTED_TEST_DONE' not in output or 'NOTED_TEST_FAIL' in output:
                failures.append('QML integration failed:\n' + output)
    if len(calls) != 2:
        failures.append(f'expected two chooser requests, got {len(calls)}')
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print('PASS: private title, snapshot, cancel, save, and repeated open')
    return 0


if __name__ == '__main__':
    if sys.argv[1:] == ['--portal']:
        sys.exit(run_portal_test())
    unittest.main()
