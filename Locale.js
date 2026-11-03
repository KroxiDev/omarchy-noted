.pragma library

function normalize(value) {
    var code = String(value || "").trim().split(/[.@]/)[0].replace(/_/g, "-")
    if (!/^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*$/.test(code)) return "en"
    var parts = code.split("-")
    parts[0] = parts[0].toLowerCase()
    if (parts[0] !== "en" && parts[0] !== "es") return "en"
    for (var i = 1; i < parts.length; i++)
        parts[i] = parts[i].length === 2 ? parts[i].toUpperCase() : parts[i]
    return parts.join("-")
}

function choose(setting, omarchy, lcAll, lcMessages, lang) {
    var explicit = String(setting || "auto").trim()
    return normalize(explicit && explicit !== "auto"
        ? explicit : String(omarchy || "").trim() || lcAll || lcMessages || lang || "en")
}

function format(template, args) {
    return String(template).replace(/%([1-9][0-9]*)/g, function(token, number) {
        var index = Number(number) - 1
        return args && index < args.length ? String(args[index]) : token
    })
}
