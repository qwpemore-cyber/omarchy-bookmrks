// Pure helpers for the bookmarks data file. Kept free of QML types so the
// parsing, normalising, and serialising rules can be reasoned about (and
// unit-tested) on their own; Sidebar.qml owns every side effect.
//
// Stored shape in ~/.config/omarchy/bookmarks.json:
//   { "version": 1, "bookmarks": [ { id, type, label, target, icon } ] }
//
// Everything that reaches disk goes through normalize() first, so a
// hand-edited or truncated file can never put a half-formed bookmark in
// front of the UI.

var VERSION = 1
var TYPES = ["url", "app", "cmd"]

// Glyphs used when a bookmark carries no icon, and for the modal's type
// selector. These are the same codepoints the stock Omarchy menu uses for
// "Browser", "Apps", and "Terminal", so they are known to render with the
// Nerd Font this desktop already ships. Built with fromCodePoint because
// Material Design Icons codepoints run past U+FFFF, where a \uXXXX escape
// silently stops after four hex digits.
var TYPE_GLYPHS = {
  url: String.fromCodePoint(0x0F488),
  app: String.fromCodePoint(0xF003B),
  cmd: String.fromCodePoint(0x0F489),
  separator: "."
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

function labelForType(type, target) {
  var text = String(target === undefined || target === null ? "" : target).trim()
  if (text === "") return ""
  if (isSupportedType(type) && type === "url") {
    var withoutScheme = text.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "")
    var cut = withoutScheme.indexOf("/")
    if (cut !== -1) withoutScheme = withoutScheme.slice(0, cut)
    return withoutScheme || text
  }
  // A command line is mostly flags and paths; the first word is the useful
  // label, and the desktop id is the executable in a shell command too.
  var first = text.split(/\s+/)[0]
  var slash = first.lastIndexOf("/")
  if (slash !== -1) first = first.slice(slash + 1)
  return first || text
}

function normalizeEntry(raw) {
  if (!isPlainObject(raw)) return null

  var type = String(raw.type || "").trim().toLowerCase()
  if (!isSupportedType(type)) return null

  var target = String(raw.target === undefined || raw.target === null ? "" : raw.target).trim()
  if (target === "") return null

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
// argument, whatever it contains.
function argvFor(entry) {
  var normalized = normalizeEntry(entry)
  if (!normalized) return []

  if (normalized.type === "url") {
    return ["omarchy-launch-webapp", normalized.target]
  }
  if (normalized.type === "app") {
    return isDesktopId(normalized.target)
      ? ["gtk-launch", normalized.target]
      : ["omarchy-launch", normalized.target]
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
