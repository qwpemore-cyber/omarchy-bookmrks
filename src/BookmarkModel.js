// Pure helpers for the bookmarks data file. Kept free of QML types so the
// parsing, normalising, and serialising rules can be reasoned about (and
// unit-tested) on their own; Sidebar.qml owns every side effect.
//
// If a field will not validate, a save lands wrong, a command runs the
// wrong thing, or an icon never appears: normalize(), validate(),
// launchArgv(), iconFor(). Those four are the whole surface.
//
// Stored shape in ~/.config/omarchy/bookmarks.json:
//   { "version": 1, "bookmarks": [ { id, type, label, target, icon } ] }
//
// Everything that reaches disk goes through normalize() first, so a
// hand-edited or truncated file can never put a half-formed bookmark in
// front of the UI.

var VERSION = 1
var TYPES = ["url", "app", "cmd", "file"]

// Glyphs used when a bookmark carries no icon, and for the modal's type
// selector. These are the same codepoints the stock Omarchy menu uses for
// "Browser", "Apps", and "Terminal", so they are known to render with the
// Nerd Font this desktop already ships. Built with fromCodePoint because
// Material Design Icons codepoints run past U+FFFF, where a \uXXXX escape
// silently stops after four hex digits.
//
// None of them are in omarchy.ttf; they are all in the JetBrainsMono Nerd Font
// that `fc-match monospace` resolves to, and reach it through the fallback
// chain. That is why the panel says `Style.font.family` is plain "monospace"
// yet the glyphs still draw. Every candidate here was checked against the
// font's cmap rather than assumed, since a codepoint that is not in the font
// renders as a box and nothing else reports it.
var TYPE_GLYPHS = {
  url: String.fromCodePoint(0x0F488),
  app: String.fromCodePoint(0xF003B),
  cmd: String.fromCodePoint(0x0F489),
  file: String.fromCodePoint(0x0F15B),
  separator: "."
}

// QML's `lineHeight` multiplies the font's own line height, not its pixel
// size, so a multiplier that reads correctly in one font is double spacing in
// another. With omarchy.ttf a 12px font has a ~16px natural line height, so
// lineHeight 1.3 produced 21px lines and the paragraph looked like it had a
// blank line between every line. This turns a wanted leading, in pixels, into
// the multiplier Qt actually multiplies by, so the leading is what it says
// whatever font is in use.
function lineHeightFor(leadingPx, naturalPx) {
  if (!(naturalPx > 0)) return 1
  return leadingPx / naturalPx
}

function isSupportedType(type) {
  return TYPES.indexOf(String(type)) !== -1
}

function typeGlyph(type) {
  return TYPE_GLYPHS[isSupportedType(type) ? type : "cmd"] || TYPE_GLYPHS.cmd
}

function isSeparatorGlyph(value) {
  return String(value) === TYPE_GLYPHS.separator
}

// Nerd-font glyphs live in the Private Use Area: the legacy block at
// U+E000-U+F8FF, and the Material Design Icons block above U+F0000. Emoji,
// Arabic, and CJK all sit outside those, so a single character in range is
// a glyph and anything else is a word that wants a text renderer. Iterating
// with Array.from counts code points, not UTF-16 units, so a supplementary
// emoji is one item here and is rejected by the range test.
function isIconGlyph(value) {
  var text = String(value === undefined || value === null ? "" : value)
  if (text === "" || isSeparatorGlyph(text)) return false
  var points = Array.from(text)
  if (points.length !== 1) return false
  var code = points[0].codePointAt(0)
  return (code >= 0xE000 && code <= 0xF8FF) || (code >= 0xF0000 && code <= 0xFFFFD)
}

// Desktop entries are namespaced reverse-DNS ("org.gnome.Nautilus"); a bare
// executable has no dot, so the two never collide on the same field.
function isDesktopId(value) {
  return /^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9][A-Za-z0-9._-]*$/.test(String(value))
}

// Cross-device-unique and independent of label edits, so reordering or
// renaming a bookmark never orphans its row.
function makeId() {
  var stamp = Date.now().toString(36)
  var salt = Math.floor(Math.random() * 0x1000000).toString(36)
  return "b" + stamp + salt
}

// A file label is the last path segment, and the whole trimmed string is the
// path: splitting on whitespace first would cut "/home/bo/My Notes/a.md" down
// to "My". The `~` is dropped so the label reads as a name, not as a shell
// token the user has to expand.
function fileLabel(target) {
  var text = String(target === undefined || target === null ? "" : target).trim()
  if (text === "") return ""
  var cut = text.lastIndexOf("/")
  var name = cut === -1 ? text : text.slice(cut + 1)
  if (name === "") {
    // A trailing slash names the directory above it, not nothing.
    var parent = text.slice(0, cut).replace(/\/+$/, "")
    var up = parent.lastIndexOf("/")
    name = up === -1 ? parent : parent.slice(up + 1)
  }
  return name || text
}

function labelForType(type, target) {
  var text = String(target === undefined || target === null ? "" : target).trim()
  if (text === "") return ""
  if (isSupportedType(type) && type === "url") {
    var withoutScheme = text.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "")
    var cut = withoutScheme.indexOf("/")
    if (cut !== -1) withoutScheme = withoutScheme.slice(0, cut)
    return withoutScheme || text
  }
  if (isSupportedType(type) && type === "file") return fileLabel(text)
  // A command line is mostly flags and paths; the first word is the useful
  // label, and the desktop id is the executable in a shell command too.
  var first = text.split(/\s+/)[0]
  var slash = first.lastIndexOf("/")
  if (slash !== -1) first = first.slice(slash + 1)
  return first || text
}

// A bare relative path is refused: it would resolve against whatever directory
// the panel happened to be started in, so the same bookmark could open two
// different files depending on how the session was launched. `~` is allowed and
// stored unexpanded, which is what makes a file bookmark survive a move to
// another machine — the home directory is expanded at launch, not on disk, so
// `/home/bo/notes.md` never has to be edited to work as `/home/someone-else`.
function isFileTarget(value) {
  var text = String(value)
  return text === "~" || text.indexOf("~/") === 0 || text.charAt(0) === "/"
}

function expandHome(path, home) {
  var text = String(path === undefined || path === null ? "" : path)
  var root = String(home === undefined || home === null ? "" : home)
  if (text !== "~" && text.indexOf("~/") !== 0) return text
  if (root === "") return text
  if (root.charAt(root.length - 1) === "/") root = root.slice(0, -1)
  return text === "~" ? root : root + text.slice(1)
}

function normalizeEntry(raw) {
  if (!isPlainObject(raw)) return null

  var type = String(raw.type || "").trim().toLowerCase()
  if (!isSupportedType(type)) return null

  var target = String(raw.target === undefined || raw.target === null ? "" : raw.target).trim()
  if (target === "") return null
  if (type === "file" && !isFileTarget(target)) return null

  var icon = String(raw.icon === undefined || raw.icon === null ? "" : raw.icon).trim()
  // A glyph only makes sense as an icon; in the target field it is far more
  // likely to be someone pasting a glyph where a URL belonged.
  if (isIconGlyph(target) && icon === "") icon = target

  var label = String(raw.label === undefined || raw.label === null ? "" : raw.label).trim()
  if (label === "") label = labelForType(type, target)

  var id = String(raw.id === undefined || raw.id === null ? "" : raw.id).trim()
  if (id === "") id = makeId()

  return {
    id: id,
    type: type,
    label: label,
    target: target,
    icon: isIconGlyph(icon) || isDesktopId(icon) ? icon : ""
  }
}

function parse(rawText) {
  var parsed
  try {
    parsed = JSON.parse(String(rawText === undefined || rawText === null ? "" : rawText))
  } catch (e) {
    return { version: VERSION, bookmarks: [] }
  }
  return fromObject(parsed)
}

function fromObject(parsed) {
  var list = Array.isArray(parsed) ? parsed : (parsed && Array.isArray(parsed.bookmarks) ? parsed.bookmarks : [])
  var out = []
  var seen = {}

  for (var i = 0; i < list.length; i++) {
    var entry = normalizeEntry(list[i])
    if (!entry) continue
    // Duplicated ids would make the ListModel roles ambiguous, and a
    // hand-edited file is the only way to get one.
    if (seen[entry.id]) entry.id = makeId()
    seen[entry.id] = true
    out.push(entry)
  }

  return { version: VERSION, bookmarks: out }
}

function serialize(state) {
  return JSON.stringify({ version: VERSION, bookmarks: fromObject(state).bookmarks }, null, 2) + "\n"
}

function append(state, entry) {
  var normalized = normalizeEntry(entry)
  if (!normalized) return fromObject(state).bookmarks
  return fromObject(state).bookmarks.concat([normalized])
}

function updateAt(state, index, entry) {
  var list = fromObject(state).bookmarks.slice()
  var normalized = normalizeEntry(entry)
  if (!normalized || index < 0 || index >= list.length) return list
  normalized.id = list[index].id
  list[index] = normalized
  return list
}

function removeAt(state, index) {
  var list = fromObject(state).bookmarks.slice()
  if (index < 0 || index >= list.length) return list
  list.splice(index, 1)
  return list
}

function moveBy(state, from, delta) {
  var list = fromObject(state).bookmarks.slice()
  var to = from + delta
  if (from < 0 || from >= list.length || to < 0 || to >= list.length) return list
  var moved = list.splice(from, 1)[0]
  list.splice(to, 0, moved)
  return list
}

// A target typed by a person, or edited by one, is never handed to a shell
// as a command line: argv form means the string can only ever be a single
// argument, whatever it contains. `home` is passed in rather than read from the
// environment so this stays a pure function, and so a file bookmark written on
// one machine finds the same file under a different user name on the next one.
function argvFor(entry, home) {
  var normalized = normalizeEntry(entry)
  if (!normalized) return []

  if (normalized.type === "url") {
    return ["omarchy-launch-webapp", normalized.target]
  }
  if (normalized.type === "file") {
    // xdg-open hands the path to whatever application the user already
    // registered for that type, which is what "open this file" should mean on
    // a desktop. Directories work through the same call.
    return ["xdg-open", expandHome(normalized.target, home)]
  }
  if (normalized.type === "app") {
    // A desktop id is launched by its .desktop file, which carries the
    // Exec line, the icon, and the startup hints. Anything else is a bare
    // command, and that goes through uwsm-app — the same wrapper the shell's
    // own panels use, so the app is started in the graphical session rather
    // than in this process's environment.
    return isDesktopId(normalized.target)
      ? ["gtk-launch", normalized.target]
      : ["uwsm-app", "--", normalized.target]
  }
  return ["bash", "-c", normalized.target]
}

// Mirrors BookmarkItem.qml's decision about which renderer the icon field
// deserves, so a saved bookmark previews the same way here.
function iconKind(entry) {
  var normalized = normalizeEntry(entry)
  if (!normalized) return "none"
  if (isIconGlyph(normalized.icon)) return "glyph"
  if (isDesktopId(normalized.icon)) return "app"
  return "none"
}

function labelFor(entry) {
  return normalizeEntry(entry).label
}

function typeFor(entry) {
  return normalizeEntry(entry).type
}

function targetFor(entry) {
  return normalizeEntry(entry).target
}

function idFor(entry) {
  return normalizeEntry(entry).id
}

// Local stand-in for qs.Commons Util.isPlainObject, so this file stays
// importable (and testable) outside a QML engine.
function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}
