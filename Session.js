.pragma library

// Shared only by this plugin's bar instances. Hidden measuring copies do not
// own IPC. Elect a new owner when a bar appears, disappears, or changes layout.
var widgets = []
var undoStack = []

function register(widget) {
    if (widgets.indexOf(widget) < 0) widgets.push(widget)
    widget.undoStack = undoStack.slice()
    elect()
}

function unregister(widget) {
    widget.ipcOwner = false
    widgets = widgets.filter(function(candidate) { return candidate !== widget })
    elect()
}

function elect() {
    var owner = widgets.filter(function(widget) { return widget.canOwnIpc })[0]
    for (var i = 0; i < widgets.length; i++) {
        var widget = widgets[i]
        if (widget !== owner) widget.ipcOwner = false
    }
    if (owner) owner.ipcOwner = true
}

function activate(widget) {
    for (var i = 0; i < widgets.length; i++) {
        var other = widgets[i]
        if (other !== widget && (other.dialogOpen || other.transitionBusy)) return false
    }
    for (var j = 0; j < widgets.length; j++) {
        var peer = widgets[j]
        if (peer !== widget && peer.opened) {
            peer.close()
            if (peer.opened || peer.transitionBusy) return false
        }
    }
    return true
}

function dispatch(action, focusedScreen) {
    var visible = widgets.filter(function(widget) { return widget.canOwnIpc })
    if (!visible.length) return
    if (action === "close") {
        visible.forEach(function(widget) { if (widget.opened) widget.close() })
        return
    }
    var chosen = visible.filter(function(widget) { return widget.screenName === focusedScreen })[0] || visible[0]
    chosen[action]()
}

function setUndo(stack) {
    undoStack = stack.slice()
    widgets.forEach(function(widget) { widget.undoStack = undoStack.slice() })
}

function pushUndo(path, folder) { setUndo(undoStack.concat([{path: path, folder: folder || ""}])) }

function barOnScreen(name) {
    var widget = widgets.filter(function(candidate) {
        return candidate.canOwnIpc && candidate.screenName === name
    })[0]
    if (!widget || !widget.barWindow || !widget.bar) return null
    return {edge: widget.bar.position, width: widget.barWindow.width, height: widget.barWindow.height}
}
