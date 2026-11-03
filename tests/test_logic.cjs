const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..');
function load(name) {
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync(path.join(root, name), 'utf8').replace(/^\.pragma library\s*/, ''), context);
  return context;
}
const locale = load('Locale.js');
for (const [args, expected] of [
  [['es', 'en', 'en_US.UTF-8'], 'es'],
  [['auto', 'es-MX', 'en_US.UTF-8'], 'es-MX'],
  [['auto', '', 'es_AR.UTF-8'], 'es-AR'],
  [['auto', '', '', 'es_ES.UTF-8', 'en_US.UTF-8'], 'es-ES'],
  [['auto', '', '', '', 'en_US.UTF-8'], 'en-US'],
  [['auto', '', '', '', 'fr_FR.UTF-8'], 'en'],
  [['garbage', 'es'], 'en'],
  [['auto', '', 'C.UTF-8'], 'en'],
]) assert.equal(locale.choose(...args), expected);
const en = JSON.parse(fs.readFileSync(path.join(root, 'i18n/en.json')));
const es = JSON.parse(fs.readFileSync(path.join(root, 'i18n/es.json')));
assert.deepEqual(Object.keys(en).sort(), Object.keys(es).sort());
for (const key of Object.keys(en)) {
  assert.deepEqual(en[key].match(/%\d+/g), es[key].match(/%\d+/g), key);
}
assert.equal(locale.format('%1 / %2 / %1', ['a%2', 'b']), 'a%2 / b / a%2');
const session = load('Session.js');
function widget(screenName, visible = true) {
  return {
    screenName, canOwnIpc: visible, ipcOwner: false, opened: false,
    dialogOpen: false, transitionBusy: false, undoStack: [],
    open() { if (session.activate(this)) this.opened = true; },
    close() { this.opened = false; },
    toggle() { this.opened ? this.close() : this.open(); },
    newNote() { this.open(); },
  };
}
const hidden = widget('screen-a', false), first = widget('screen-a'), second = widget('screen-b');
[hidden, first, second].forEach(w => session.register(w));
assert.equal(first.ipcOwner, true);
assert.equal(hidden.ipcOwner || second.ipcOwner, false);
session.dispatch('toggle', 'screen-b');
assert.equal(second.opened, true);
session.dispatch('open', 'screen-a');
assert.equal(first.opened, true);
assert.equal(second.opened, false);
first.dialogOpen = true;
session.dispatch('open', 'screen-b');
assert.equal(second.opened, false);
first.dialogOpen = false;
session.dispatch('toggle', 'screen-a');
assert.equal(first.opened, false);
session.dispatch('open', 'no-bar');
assert.equal(first.opened, true);
session.pushUndo('/note.md', '/notes');
assert.equal(second.undoStack[0].path, '/note.md');
assert.equal(second.undoStack[0].folder, '/notes');
session.unregister(first);
assert.equal(second.ipcOwner, true);
session.dispatch('close', 'screen-a');
assert.equal(second.opened, false);
console.log('PASS: locale precedence, catalogs, monitor routing, IPC handover, modal exclusion, shared undo');
