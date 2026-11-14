"""Run via test_fileview.sh as a regular user; never touches real notes."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

from test_store import module

ROOT = Path(__file__).resolve().parents[1]

QML = '''import QtQuick
import Quickshell
import Quickshell.Io
import SESSION as Session
ShellRoot {
    id: root
    property string noteId: DRAFT_PATH
    property string recoveryDirectory: RECOVERY_PATH
    property bool dirty: true
    property bool persisted: false
    property bool ipcOwner: false
    property bool writing: false
    property bool loadFailed: false
    property bool writeFailed: false
    property bool writeSucceeded: false
    property bool recoverySucceeded: false
    property bool diskConflict: false
    property string lastDiskText: ""
    property string notice: ""
    property string helper: ""
    property string activeFolder: ""
    QtObject { id: editor; property string text: "DRAFT_CONTENT" }
    QtObject { id: i18n; function t(key) { return key } }
    Timer { id: debounce }
    Timer { id: externalDelay }
    Component.onCompleted: Qt.callLater(runTest)
    function runTest() {
        if (!flush()) { console.log("PRIVACY_TEST_FAIL draft save"); Qt.quit(); return }
        noteId = ORIGINAL_PATH
        editor.text = "PRIVATE_NOTE\\nunsaved changes"
        lastDiskText = "PRIVATE_NOTE"
        persisted = true
        dirty = true
        Qt.quit()
    }
FLUSH
RECOVERY_CODE
FILE_VIEWS
}
'''


class FileViewPrivacyTests(unittest.TestCase):
    def test_new_state(self):
        self.check_private_copies(existing=False)

    def test_existing_state(self):
        self.check_private_copies(existing=True)

    def check_private_copies(self, existing):
        self.assertNotEqual(os.getuid(), 0, 'Run this permission regression as a regular user')
        previous = os.umask(0o022)
        self.addCleanup(os.umask, previous)
        with tempfile.TemporaryDirectory(prefix='noted-privacy-', dir='/tmp') as temp:
            fixture = Path(temp)
            fixture.chmod(0o755)  # Searchable ancestors must not mask the bug.
            state = fixture / 'state' / 'noted'
            if existing:
                (state / 'drafts').mkdir(parents=True)
                (state / 'drafts' / 'old.md').write_text('OLD_DRAFT')
            store = module.Store(documents=fixture / 'Documents', state=state)
            store.execute({'op': 'init'})
            draft = Path(store.execute({'op': 'allocate'})['path'])
            private = fixture / 'private'
            private.mkdir(mode=0o700)
            original = private / 'original.md'
            original.write_text('PRIVATE_NOTE')
            original.chmod(0o600)
            private.chmod(0o500)  # Force atomic save failure at shell shutdown.
            try:
                fake_bin = fixture / 'bin'
                fake_bin.mkdir()
                notify = fake_bin / 'notify-send'
                notify.write_text('#!/bin/sh\nexit 0\n')
                notify.chmod(0o700)
                env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='basic', QT_QUICK_CONTROLS_STYLE='Basic')
                for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS'):
                    env.pop(key, None)
                for key in ('HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME'):
                    directory = fixture / key
                    directory.mkdir(mode=0o700 if key == 'XDG_RUNTIME_DIR' else 0o755)
                    env[key] = str(directory)
                env['PATH'] = str(fake_bin) + ':' + os.environ['PATH']
                # Execute the real save/destruction code rather than duplicating it.
                panel = (ROOT / 'Panel.qml').read_text()
                replacements = {
                    'SESSION': json.dumps(str(ROOT / 'Session.js')),
                    'DRAFT_PATH': json.dumps(str(draft)),
                    'RECOVERY_PATH': json.dumps(str(store.drafts)),
                    'ORIGINAL_PATH': json.dumps(str(original)),
                    'FLUSH': panel[panel.index('    function flush('):panel.index('    function reloadCurrent(')],
                    'RECOVERY_CODE': panel[panel.index('    function saveRecovery('):panel.index('\n    Timer { interval: 250;')],
                    'FILE_VIEWS': panel[panel.index('    FileView {\n        id: primary'):panel.index('    Process {\n        id: worker')],
                }
                source = QML
                for key, value in replacements.items():
                    source = source.replace(key, value)
                shell = fixture / 'shell.qml'
                shell.write_text(source)
                result = subprocess.run(['quickshell', '--no-color', '-p', str(shell)], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn('PRIVACY_TEST_FAIL', result.stdout + result.stderr)
                recovered = list(store.drafts.glob('recovered-*.md'))
                self.assertEqual(len(recovered), 1, result.stdout + result.stderr)
                self.assertEqual(draft.read_text(), 'DRAFT_CONTENT')
                self.assertEqual(recovered[0].read_text(), 'PRIVATE_NOTE\nunsaved changes')
                self.assertEqual(original.read_text(), 'PRIVATE_NOTE')
                self.assertEqual(stat.S_IMODE(original.stat().st_mode), 0o600)
                for directory in (store.state, store.drafts):
                    self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE(store.directory.stat().st_mode), 0o755)
                if existing:
                    self.assertEqual((store.drafts / 'old.md').read_text(), 'OLD_DRAFT')
            finally:
                private.chmod(0o700)


if __name__ == '__main__':
    unittest.main()
