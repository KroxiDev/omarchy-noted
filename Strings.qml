import QtQuick
import Quickshell
import Quickshell.Io
import "Locale.js" as Locale

Item {
    id: root
    property string setting: "auto"
    property string omarchyLanguage: ""
    property var english: ({})
    property var spanish: ({})
    readonly property string localeCode: Locale.choose(setting, omarchyLanguage,
        Quickshell.env("LC_ALL"), Quickshell.env("LC_MESSAGES"), Quickshell.env("LANG"))
    readonly property string language: localeCode.split("-")[0]

    function t(key, args) {
        var catalog = language === "es" ? spanish : english
        return Locale.format(catalog[key] || english[key] || key, args)
    }
    function message(value) {
        if (!value) return ""
        if (Array.isArray(value)) return value.map(function(item) { return root.message(item) }).join("\n")
        return typeof value === "string" ? t(value) : t(value.error || "operation_failed", value.args)
    }
    function parse(text) {
        try { return JSON.parse(text) } catch (error) { return {} }
    }
    FileView {
        path: Qt.resolvedUrl("i18n/en.json")
        blockLoading: true
        onLoaded: root.english = root.parse(text())
    }
    FileView {
        path: Qt.resolvedUrl("i18n/es.json")
        blockLoading: true
        onLoaded: root.spanish = root.parse(text())
    }
    FileView {
        path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/language"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.omarchyLanguage = text().trim()
        onLoadFailed: root.omarchyLanguage = ""
        onFileChanged: reload()
    }
}
