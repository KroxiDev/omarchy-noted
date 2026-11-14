#!/usr/bin/env bash
# Uses offscreen Qt only: no Chromium, Wayland surface, or real user notes.
set -euo pipefail

if [[ $(id -u) == 0 ]]; then
  echo "Run this permission regression as a non-root user." >&2
  exit 1
fi
command -v quickshell >/dev/null
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture=$(mktemp -d /tmp/noted-fileview-test.XXXXXX)
cleanup() {
  chmod u+rwx "$fixture/notes" 2>/dev/null || true
  rm -rf -- "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/notes" "$fixture/runtime" "$fixture/home" "$fixture/config" "$fixture/cache"
chmod 700 "$fixture/runtime"
printf OLD > "$fixture/notes/note.md"
chmod 555 "$fixture/notes"
cp "$test_dir/fileview_retry.qml" "$fixture/shell.qml"

if ! env -u DISPLAY -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=basic \
    QT_QUICK_CONTROLS_STYLE=Basic HOME="$fixture/home" \
    XDG_RUNTIME_DIR="$fixture/runtime" XDG_CONFIG_HOME="$fixture/config" \
    XDG_CACHE_HOME="$fixture/cache" NOTED_TEST_FIXTURE="$fixture" \
    timeout 15s quickshell --no-color -p "$fixture/shell.qml" > "$fixture/log" 2>&1; then
  cat "$fixture/log" >&2
  exit 1
fi
if grep -q 'NOTED_TEST_FAIL' "$fixture/log" || \
    [[ $(grep -c 'NOTED_TEST_PASS' "$fixture/log") != 6 ]] || \
    ! cmp -s "$fixture/notes/note.md" <(printf DESTRUCTOR); then
  cat "$fixture/log" >&2
  echo "FileView retry/destruction regression failed." >&2
  exit 1
fi
echo "PASS: failed retry, permission recovery, repeated save, and destruction persistence."
python3 "$test_dir/fileview_privacy.py"
