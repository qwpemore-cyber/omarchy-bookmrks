// Pure helpers for the bookmarks data file. Kept free of QML types so the
// parsing, normalising, and serialising rules can be reasoned about (and
// unit-tested) on their own; Sidebar.qml owns every side effect.
//
// Stored shape in ~/.config/omarchy/bookmarks.json:
//   { "version": 2, "items": [ node, … ] }
// where a node is one of
//   { id, kind:"bookmark", type, label, target, icon, pinned }
//   { id, kind:"folder",   label, icon, items:[node, …] }
//   { id, kind:"section",  label, icon }
//   { id, kind:"separator" }                       // a rule, and nothing else
//
// `kind` is Firefox's own distinction (types 1, 2 and 3 in places.sqlite) and
// the reason the model is worth having: a folder has no `target` at all, so it
// cannot be launched even by a mistake. Type says what a row *is*; the presence
// of a target says what can be *run*.
//
// Order IS the nesting. There is no `position` and no `order` field: a node's
// place in the file is its place in the list, and moving one means moving it
// inside `items`. That removes the whole class of bugs where a stored index
// and a displayed index drift apart, and it is why Firefox can hand the same
// job to the Dogear backend and the JSON backup without either one owning a
// counter.
//
// v1 files ({ "version": 1, "bookmarks": [ … ] }) still read: every entry
// becomes a top-level bookmark node, so an upgrade keeps the list and writes
// v2 on the next save. That is one-way by design — an older build cannot read
// a v2 file — which is why Sidebar.qml copies the file to bookmarks.json.bak
// before the first v2 write.
//
// Everything that reaches disk goes through normalizeNode() first, so a
// hand-edited or truncated file can never put a half-formed node in front of
// the UI. Validation is forgiving in exactly one direction: a folder with a
// missing label keeps its children under "(unnamed)" instead of being dropped,
// because dropping a node with descendants is the one way normalising a file
// could lose data it was supposed to be preserving.

var VERSION = 2
var TYPES = ["url", "app", "cmd", "file"]
var KINDS = ["bookmark", "folder", "section", "separator"]

// A hand-edited file can nest as deep as it likes; the tree walk recurses, so
// an unbounded depth is a stack overflow rather than a rejected file. 24 is
// far past anything a person arranges by hand and shallow enough to walk.
var MAX_DEPTH = 24

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
  file: String.fromCodePoint(0xF15B),
  separator: "."
}

var KIND_GLYPHS = {
  folder: String.fromCodePoint(0xF07B),
  folderOpen: String.fromCodePoint(0xF07C),
  section: String.fromCodePoint(0xF0C9),
  pin: String.fromCodePoint(0xF08D)
}

var CHEVRON_DOWN = String.fromCodePoint(0xF0A7)
var CHEVRON_RIGHT = String.fromCodePoint(0xF105)

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

function isSupportedKind(kind) {
  return KINDS.indexOf(String(kind)) !== -1
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

function normalizeKind(raw) {
  var kind = String(raw === undefined || raw === null ? "" : raw).trim().toLowerCase()
  // A v1 entry has no kind, and a bare target-bearing object is a bookmark by
  // any other reading; anything else unknown is refused rather than guessed.
  if (kind === "") return "bookmark"
  return isSupportedKind(kind) ? kind : ""
}

function normalizePinned(raw) {
  if (raw === true) return true
  var text = String(raw === undefined || raw === null ? "" : raw).trim().toLowerCase()
  return text === "true" || text === "1" || text === "yes"
}

function normalizeNode(raw, depth, seen) {
  if (!isPlainObject(raw)) return null

  var level = depth === undefined || depth === null ? 0 : depth
  if (level > MAX_DEPTH) return null
  var known = seen || {}

  var kind = normalizeKind(raw.kind)
  if (kind === "") return null

  var id = String(raw.id === undefined || raw.id === null ? "" : raw.id).trim()
  if (id === "") id = makeId()

  var icon = String(raw.icon === undefined || raw.icon === null ? "" : raw.icon).trim()

  if (kind === "bookmark") {
    var type = String(raw.type || "").trim().toLowerCase()
    if (!isSupportedType(type)) return null

    var target = String(raw.target === undefined || raw.target === null ? "" : raw.target).trim()
    if (target === "") return null
    if (type === "file" && !isFileTarget(target)) return null

    // A glyph only makes sense as an icon; in the target field it is far more
    // likely to be someone pasting a glyph where a URL belonged.
    if (isIconGlyph(target) && icon === "") icon = target

    // An empty name falls back to something recognisable from the target, the
    // way a browser names a bookmark you gave none. It is worth knowing that
    // clearing a label does not leave a blank row: it renames the row to its
    // host, its filename or its first word. The target is never touched, so
    // nothing is lost by doing it, and the panel shows the new name at once.
    var label = String(raw.label === undefined || raw.label === null ? "" : raw.label).trim()
    if (label === "") label = labelForType(type, target)

    return {
      id: id,
      kind: "bookmark",
      type: type,
      label: label,
      target: target,
      icon: isIconGlyph(icon) || isDesktopId(icon) ? icon : "",
      pinned: normalizePinned(raw.pinned)
    }
  }

  // A separator is a line, not a row with an empty name. Firefox makes it a real
  // node type (TYPE_X_MOZ_PLACE_SEPARATOR, created by PlacesTransactions
  // .NewSeparator) for the same reason: a section with no name normalises to
  // "(unnamed)", so a nameless section is a heading that says "(unnamed)" and a
  // rule under it — not a bare rule. There is no way to spell this with the
  // three kinds that came before, so it is a fourth.
  //
  // No label, because there is nothing to name. No icon, because the rule is
  // the whole of it. No pinned, for the reason the section has none, and no
  // items, because a separator is not a container and an indent that found one
  // would have nowhere to put what it moved.
  if (kind === "separator") {
    return { id: id, kind: "separator", icon: "" }
  }

  // A folder or a section has nothing to derive a label from, so a missing one
  // would render as a blank row. It is filled in rather than refused: for a
  // folder, refusing would take every child with it, and normalising a file is
  // supposed to preserve data, not quietly trim it.
  var name = String(raw.label === undefined || raw.label === null ? "" : raw.label).trim()
  if (name === "") name = "(unnamed)"

  var node = {
    id: id,
    kind: kind,
    label: name,
    icon: isIconGlyph(icon) ? icon : ""
  }

  if (kind === "folder") {
    node.items = normalizeItems(raw.items, level + 1, known)
  }
  // A section carries no `pinned` key at all, rather than one set to false. The
  // file is read and edited by hand, and a section with `"pinned": false` in it
  // reads as a thing that could be pinned; setting it true would then do
  // nothing at all, which is the worst thing a field in a user's file can do.
  // The projection still reports `pinned: false` for a section, so the rows
  // have one shape whatever their kind.

  return node
}

// Normalises a list, minting an id for any duplicate. Two nodes sharing an id
// would make the panel's row -> node translation ambiguous, and a hand-edited
// file is the only way to get one. The `seen` map is threaded through the whole
// tree, not per list, so a duplicate id across two folders is caught too.
function normalizeItems(list, level, seen) {
  var known = seen || {}
  var out = []
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length; i++) {
    var node = normalizeNode(list[i], level, known)
    if (!node) continue
    if (known[node.id]) node.id = makeId()
    known[node.id] = true
    out.push(node)
  }
  return out
}

// Kept because the modal and the CLI both hand a bookmark-shaped object to
// updateAt() and append(), and because a v1 caller has no kind to pass.
function normalizeEntry(raw) {
  var node = normalizeNode(raw, 0, {})
  return node && node.kind === "bookmark" ? node : null
}

function parse(rawText) {
  var parsed
  try {
    parsed = JSON.parse(String(rawText === undefined || rawText === null ? "" : rawText))
  } catch (e) {
    return { version: VERSION, items: [] }
  }
  return fromObject(parsed)
}

// Accepts a v2 object ({items}), a v1 object ({bookmarks}), or a bare array of
// entries, because a bare array is what the panel re-wraps every mutation's
// result in, and both shapes have to survive a round trip through it.
function itemsOf(parsed) {
  if (Array.isArray(parsed)) return parsed
  if (!isPlainObject(parsed)) return []
  if (Array.isArray(parsed.items)) return parsed.items
  if (Array.isArray(parsed.bookmarks)) return parsed.bookmarks
  return []
}

function fromObject(parsed) {
  return { version: VERSION, items: normalizeItems(itemsOf(parsed), 0, {}) }
}

// What a mutation hands back to the caller: the top level of the tree, ready
// to be wrapped by stateOf() or fed straight back into fromObject().
// Wraps a list of top-level nodes in the shape the file is written in. The
// argument may also be a whole state, because `stateOf(stateOf(x))` is an easy
// thing to write and it must not quietly hand back an empty list: a function
// that drops the bookmarks when handed the wrong shape is the worst possible
// behaviour in a migration path, where the caller's whole job is not to lose
// them. It reads the nodes through the same helper the parser uses, so v1 and
// v2 arrive alike and a list comes back untouched.
function stateOf(parsed) {
  return { version: VERSION, items: Array.isArray(parsed) ? parsed : itemsOf(parsed) }
}

function serialize(state) {
  return JSON.stringify({ version: VERSION, items: fromObject(state).items }, null, 2) + "\n"
}

// ---- the projection -------------------------------------------------------
//
// Everything the panel draws, navigates, and mutates is a row from flatten().
// Rows are what the list shows, and a row index is the one number the panel
// passes to a mutation, so there is no second indexing scheme to keep in step
// with the first: the query the panel is showing with is part of how a row
// index is resolved, exactly as the collapsed set is.

function viewOptions(opts) {
  var raw = isPlainObject(opts) ? opts : {}
  return {
    query: String(raw.query === undefined || raw.query === null ? "" : raw.query).trim(),
    pinnedOnly: raw.pinnedOnly === true,
    collapsed: isPlainObject(raw.collapsed) ? raw.collapsed : {}
  }
}

// A filter reveals, plain collapse does not. With a query or a pinned-only view
// every folder that is visible is expanded, so what the count says is what the
// list contains; with neither, the collapsed set applies. The alternative —
// honouring collapse under a filter — makes a search's "3 of 40" lie, and a
// search that quietly hides the one row that matched is worse than no search.
function isFiltered(options) {
  return options.query !== "" || options.pinnedOnly
}

function matches(node, query) {
  var needle = String(query === undefined || query === null ? "" : query).trim().toLowerCase()
  if (needle === "") return true
  var raw = isPlainObject(node) ? node : {}
  var kind = normalizeKind(raw.kind)
  if (kind === "") return false
  var label = String(raw.label === undefined || raw.label === null ? "" : raw.label).toLowerCase()
  if (label.indexOf(needle) !== -1) return true
  if (kind !== "bookmark") return false
  var target = String(raw.target === undefined || raw.target === null ? "" : raw.target).toLowerCase()
  return target.indexOf(needle) !== -1
}

// A node matches when it matches itself, and is kept when it matches or when
// anything below it does — the difference is what makes a folder stay visible
// when only a nested bookmark was searched for. Two filters combine, so
// pinned-only plus a query means both, not whichever came first, and a folder
// or a section is still matched on its own name.
function selfMatches(node, options) {
  if (options.pinnedOnly && (node.kind !== "bookmark" || node.pinned !== true)) return false
  return matches(node, options.query)
}

// One flat map for the whole tree, filled in as the walk descends: a nested
// node's own entry has to outlive the recursive call that computed it, or the
// parent that led the walk down to it finds no flag for its own child.
function keepFlags(items, options, out) {
  var flags = out || {}
  for (var i = 0; i < items.length; i++) {
    var node = items[i]
    var keep = selfMatches(node, options)
    if (!keep && node.kind === "folder" && Array.isArray(node.items)) {
      keepFlags(node.items, options, flags)
      for (var j = 0; j < node.items.length; j++) {
        if (flags[node.items[j].id]) { keep = true; break }
      }
    }
    flags[node.id] = keep
  }
  return flags
}

function flatten(state, opts) {
  var tree = fromObject(state)
  var options = viewOptions(opts)
  var filtered = isFiltered(options)
  var keep = filtered ? keepFlags(tree.items, options) : null
  var out = []

  walk(tree.items, 0, "", [], options, filtered, keep, out)
  return out
}

function walk(items, depth, parentId, parentPath, options, filtered, keep, out) {
  for (var i = 0; i < items.length; i++) {
    var node = items[i]
    if (filtered && !keep[node.id]) continue

    var path = parentPath.concat([i])
    var children = node.kind === "folder" && Array.isArray(node.items) ? node.items : null
    var collapsed = !filtered && children !== null && options.collapsed[node.id] === true

    out.push({
      id: node.id,
      kind: node.kind,
      // Every string a row carries is a string, never undefined. A separator has
      // no label at all, so it used to arrive as undefined here, and QML renders
      // an undefined into a QString binding as the word "undefined" — or logs
      // "Unable to assign [undefined] to QString" and draws nothing, depending
      // on the property. A row whose label field is missing is a shape the rest
      // of the panel has to keep defending against, for one row kind that has no
      // name to begin with.
      label: node.label === undefined || node.label === null ? "" : node.label,
      type: node.kind === "bookmark" ? node.type : "",
      target: node.kind === "bookmark" ? node.target : "",
      icon: node.icon,
      pinned: node.kind === "bookmark" && node.pinned === true,
      depth: depth,
      parentId: parentId,
      path: path,
      hasChildren: children !== null && children.length > 0,
      childCount: children === null ? 0 : children.length,
      collapsed: collapsed
    })

    if (children !== null && !collapsed) {
      walk(children, depth + 1, node.id, path, options, filtered, keep, out)
    }
  }
}

function rowsFor(state, opts) {
  return flatten(state, opts)
}

// Returns indexes rather than nodes: the panel navigates by index, and handing
// it positions keeps one number meaning the same thing in both the full list
// and the filtered one. Over the unfiltered projection, so an index here is
// stable enough to compare against a full list.
function filterIndexes(state, query) {
  var rows = flatten(state, {})
  var out = []
  for (var i = 0; i < rows.length; i++) {
    if (matches(rows[i], query)) out.push(i)
  }
  return out
}

function filterEntries(state, query) {
  var rows = flatten(state, {})
  var out = []
  var indexes = filterIndexes(state, query)
  for (var i = 0; i < indexes.length; i++) out.push(rows[indexes[i]])
  return out
}

function rowForId(state, id, opts) {
  var rows = flatten(state, opts)
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].id === id) return rows[i]
  }
  return null
}

// The number of the row with this id, or -1. This is a separate function from
// rowForId rather than an option on it, because the two are easy to confuse at
// the call site and confusing them is not a type error: a caller that wanted
// the number got the object back, and every `row < 0` test on it is false, so
// the mutation quietly refused instead of failing loudly. A row object is
// truthy and `null >= 0` is true, so the same mistake also meant "not found"
// read as row zero to the next line down. -1 is the one value that is neither.
function indexForId(state, id, opts) {
  var rows = flatten(state, opts)
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].id === id) return i
  }
  return -1
}

// A row index arrives from QML, from a keypress handler, and from a JSON
// payload, so it is not a number this file gets to assume. NaN in particular
// passes both halves of a `row < 0 || row >= length` test and would then index
// past the end of the array.
function isRowIndex(value) {
  return typeof value === "number" && isFinite(value) && Math.floor(value) === value
}

function nodeAtRow(state, row, opts) {
  var rows = flatten(state, opts)
  if (!isRowIndex(row) || row < 0 || row >= rows.length) return null
  var path = rows[row].path
  var items = fromObject(state).items
  var node = null
  for (var i = 0; i < path.length; i++) {
    if (!Array.isArray(items) || path[i] < 0 || path[i] >= items.length) return null
    node = items[path[i]]
    items = node.items
  }
  return node
}

// The array that holds the node at `path`, plus its position in it. Every
// mutation goes through this: one place that knows how a row index turns into
// somewhere to splice.
function itemsAtPath(tree, path) {
  if (!Array.isArray(path) || path.length === 0) return null
  var items = tree.items
  for (var i = 0; i < path.length - 1; i++) {
    if (path[i] < 0 || path[i] >= items.length) return null
    var node = items[path[i]]
    if (!Array.isArray(node.items)) return null
    items = node.items
  }
  var index = path[path.length - 1]
  if (index < 0 || index >= items.length) return null
  return { parent: items, index: index, node: items[index] }
}

function pathForRow(state, row, opts) {
  var rows = flatten(state, opts)
  if (!isRowIndex(row) || row < 0 || row >= rows.length) return null
  return rows[row].path
}

// Counts the node and everything under it, so "removed folder and 7 items" is
// a number the model already had rather than one the panel counts by walking
// the tree a second time after the fact.
function countSubtree(node) {
  if (!isPlainObject(node)) return 0
  var total = 1
  if (node.kind === "folder" && Array.isArray(node.items)) {
    for (var i = 0; i < node.items.length; i++) total += countSubtree(node.items[i])
  }
  return total
}

function append(state, entry) {
  var tree = fromObject(state)
  var normalized = normalizeNode(entry, 0, {})
  if (!normalized) return tree.items
  return tree.items.concat([normalized])
}

// Adds inside the folder on `parentRow`, at the end of its children. A row that
// is not a folder, or no row at all, means the top level — which is the same
// thing `append` does, so the caller can pass the selected row straight through.
function insertInto(state, parentRow, entry, opts) {
  var tree = fromObject(state)
  var normalized = normalizeNode(entry, 0, {})
  if (!normalized) return tree.items

  var at = parentRow === undefined || parentRow === null || parentRow < 0
    ? null
    : itemsAtPath(tree, pathForRow(state, parentRow, opts))
  if (!at || at.node.kind !== "folder") return tree.items.concat([normalized])

  at.node.items.push(normalized)
  return tree.items
}

// Where a new item goes when the caller named the row it is related to, rather
// than a folder to put it in. This is Firefox's rule and it is one rule, not
// two: right-click a folder and the new item lands inside it; right-click
// anything else and it lands as the next sibling, in the same parent. The
// browser writes it as a parent guid plus an index inside that parent, and
// bumps the index as it goes so a paste keeps its order — here the row already
// knows its own path, so the sibling is a splice at path.length - 1.
//
// insertInto could not do this job. It appends inside a folder and, for
// anything that is not a folder, appends to the end of the root. So "add a
// bookmark under the one I clicked" put it in the wrong place, and "add one next
// to this bookmark" put it at the far end of the file. The keyboard row cursor
// moves between items all the time, so a new item landing somewhere unrelated
// to what was selected is not a rare edge; it is the normal case.
function insertAfterRow(state, row, entry, opts) {
  var tree = fromObject(state)
  var normalized = normalizeNode(entry, 0, {})
  if (!normalized) return tree.items
  if (row === undefined || row === null || row < 0) return tree.items.concat([normalized])

  var at = itemsAtPath(tree, pathForRow(state, row, opts))
  if (!at) return tree.items.concat([normalized])

  // A folder is a container, so "next to it" means "inside it" — the same
  // answer insertInto gives, and the end of its children is the only place a
  // container can put something it has no sibling relation to.
  if (at.node.kind === "folder" && Array.isArray(at.node.items)) {
    at.node.items.push(normalized)
    return tree.items
  }

  at.parent.splice(at.index + 1, 0, normalized)
  return tree.items
}

function updateAt(state, row, entry, opts) {
  var tree = fromObject(state)
  var at = itemsAtPath(tree, pathForRow(state, row, opts))
  if (!at) return tree.items

  // A patch is laid over the row that is already there, and only the fields it
  // actually carries. It used to be normalized on its own, so a caller that
  // wanted to rename a bookmark had to send a whole node back — label, type,
  // target, icon, pinned and all — and a script that sent just the name got a
  // refusal and no change, which looks exactly like a bug in the script.
  // Sending everything still works, and a field set to "" still clears it: the
  // merge is over the keys that are present, not over the keys that are true.
  var merged = isPlainObject(entry) ? patchNode(at.node, entry) : entry
  var normalized = normalizeNode(merged, 0, {})
  if (!normalized) return tree.items

  normalized.id = at.node.id

  // Editing a bookmark into a folder keeps what the folder already held: the
  // modal sends a kind and a label, not a tree, and silently emptying a folder
  // because someone changed a row's kind would be the worst kind of surprise.
  if (normalized.kind === "folder") {
    var existing = at.node.kind === "folder" && Array.isArray(at.node.items) ? at.node.items : []
    normalized.items = existing
  } else if (at.node.kind === "folder" && Array.isArray(at.node.items) && at.node.items.length > 0) {
    // The other direction does lose something, and it used to do it quietly.
    // A node that is no longer a folder has nowhere to put what was inside it,
    // so the save is refused and the tree comes back as it was: the user gets
    // an unchanged list and a chance to move the contents out first, which is
    // what Firefox's warning asks for. The whole subtree is still counted by
    // the caller, so nothing has to be deleted by hand to make this work.
    return tree.items
  }

  // A payload that never mentions pinning leaves the flag alone, so the four
  // types of save in the panel cannot each quietly unpin a row.
  if (!isPlainObject(entry) || !("pinned" in entry)) {
    normalized.pinned = at.node.pinned === true
  }

  at.parent[at.index] = normalized
  return tree.items
}

function removeAt(state, row, opts) {
  var tree = fromObject(state)
  var at = itemsAtPath(tree, pathForRow(state, row, opts))
  if (!at) return tree.items
  at.parent.splice(at.index, 1)
  return tree.items
}

// Moves among siblings only, the way a drag inside one folder behaves. The
// flat version this replaced moved by list position, which cannot say "stop at
// the end of this folder" — under a tree that mistake drops a bookmark into
// whatever folder happens to follow. Out of range is a no-op, so a keypress at
// the end of a folder does nothing instead of throwing a row somewhere else.
function moveBy(state, row, delta, opts) {
  var tree = fromObject(state)
  var at = itemsAtPath(tree, pathForRow(state, row, opts))
  if (!at) return tree.items
  var to = at.index + delta
  if (to < 0 || to >= at.parent.length) return tree.items
  var moved = at.parent.splice(at.index, 1)[0]
  at.parent.splice(to, 0, moved)
  return tree.items
}

function canIndent(state, row, opts) {
  var tree = fromObject(state)
  var at = itemsAtPath(tree, pathForRow(state, row, opts))
  return !!at && at.index > 0 && at.parent[at.index - 1].kind === "folder"
}

// Indenting moves a node into the folder just above it, which is Firefox's `l`
// on a bookmark tree. The target is a sibling, never a descendant, so a folder
// can never end up inside itself and there is no cycle to check for.
function indent(state, row, opts) {
  var tree = fromObject(state)
  var at = itemsAtPath(tree, pathForRow(state, row, opts))
  if (!at || at.index === 0) return tree.items

  var above = at.parent[at.index - 1]
  if (above.kind !== "folder") return tree.items
  if (!Array.isArray(above.items)) above.items = []

  at.parent.splice(at.index, 1)
  above.items.push(at.node)
  return tree.items
}

function canOutdent(state, row, opts) {
  var path = pathForRow(state, row, opts)
  return !!path && path.length > 1
}

// Outdenting lifts a node to sit just after its parent, the way a drag from a
// folder back to the list above it lands. Two positions are in play and they
// are easy to confuse: where the parent sits in the list above, and where the
// node sits in the parent's own children. The first decides where the row
// lands; the second is what gets emptied.
function outdent(state, row, opts) {
  var tree = fromObject(state)
  var path = pathForRow(state, row, opts)
  if (!path || path.length < 2) return tree.items

  var parentAt = itemsAtPath(tree, path.slice(0, -1))
  if (!parentAt || !Array.isArray(parentAt.node.items)) return tree.items

  var node = parentAt.node.items.splice(path[path.length - 1], 1)[0]

  // The row joins the list that holds its parent, one place past the parent. A
  // parent at the top level has no parent of its own, so the list is the root
  // and the parent's own index is the one to go past. Reading this the other
  // way round — the list holding the parent's *parent* — lifts a row two
  // levels instead of one, which only shows up on a row that was already two
  // folders deep, so it is worth spelling out.
  var above = path.length >= 3 ? itemsAtPath(tree, path.slice(0, -2)) : null
  var list = above ? above.node.items : tree.items
  list.splice(parentAt.index + 1, 0, node)
  return tree.items
}

function setPinned(state, row, pinned, opts) {
  var tree = fromObject(state)
  var at = itemsAtPath(tree, pathForRow(state, row, opts))
  if (!at || at.node.kind !== "bookmark") return tree.items
  at.node.pinned = normalizePinned(pinned)
  return tree.items
}

function togglePinned(state, row, opts) {
  var tree = fromObject(state)
  var at = itemsAtPath(tree, pathForRow(state, row, opts))
  if (!at || at.node.kind !== "bookmark") return tree.items
  at.node.pinned = at.node.pinned !== true
  return tree.items
}

// Collapse is panel state, not data: it is a map of id -> true, never written
// to the file. Opening a folder must not edit the user's bookmarks, and
// Firefox does not persist it either.
function toggleCollapsed(collapsed, id) {
  var next = {}
  var current = isPlainObject(collapsed) ? collapsed : {}
  for (var key in current) {
    if (Object.prototype.hasOwnProperty.call(current, key)) next[key] = current[key]
  }
  if (next[id]) delete next[id]
  else next[id] = true
  return next
}

function isCollapsed(collapsed, id) {
  return isPlainObject(collapsed) && collapsed[id] === true
}

// ---- import ----------------------------------------------------------------

// Merging twice with the same file must be a no-op, which is the whole reason a
// duplicate is recognised by what the entry *is* and not only by the id it was
// minted with: a file that has been through two machines carries ids from both,
// and the same bookmark typed twice by hand gets a different id each time.
// Bookmarks compare on type+target; folders and sections compare on kind+label,
// which is the only thing they have to compare on.
function sameEntry(a, b) {
  var x = isPlainObject(a) ? a : {}
  var y = isPlainObject(b) ? b : {}
  if (x.kind !== y.kind) return false
  if (x.kind === "bookmark") return x.type === y.type && x.target === y.target
  return x.label === y.label
}

function mergeEntries(state, incoming) {
  var tree = fromObject(state)
  var out = tree.items.slice()
  if (!Array.isArray(incoming)) return out

  for (var i = 0; i < incoming.length; i++) {
    var node = normalizeNode(incoming[i], 0, {})
    if (!node) continue
    var known = false
    for (var j = 0; j < out.length; j++) {
      if (out[j].id === node.id || sameEntry(out[j], node)) { known = true; break }
    }
    if (!known) out.push(node)
  }
  return out
}

// True when the text is already the v2 shape. The panel asks this before it
// overwrites anything, to decide whether the file is worth a backup: a v2 file
// has already been through this once, and copying it every time the panel
// starts would mean a second file that only ever changes when the panel does.
function looksLikeV2(rawText) {
  var parsed
  try {
    parsed = JSON.parse(String(rawText === undefined || rawText === null ? "" : rawText))
  } catch (e) {
    return false
  }
  return isPlainObject(parsed) && Array.isArray(parsed.items)
}

// True when the text is this plugin's own data file and not something else that
// happens to be JSON. Without this a stray bookmarks.json from other tool, or a
// settings export, would be read as "zero bookmarks" and a replace would
// quietly empty the list. Both shapes count, so a v1 file is still ours.
//
// The check is a count of the whole tree against the count that survived
// normalising, at every level, not just the top: a folder with one unusable
// child still normalises to a folder, and importing it would drop that child
// without saying so. A file nested past the depth limit is refused for the same
// reason — reading it would silently flatten the bottom of the tree.
function isCompleteNode(raw, level) {
  if (!isPlainObject(raw)) return false
  var node = normalizeNode(raw, level, {})
  if (!node) return false
  if (node.kind !== "folder" || !Array.isArray(raw.items)) return true
  for (var i = 0; i < raw.items.length; i++) {
    if (!isCompleteNode(raw.items[i], level + 1)) return false
  }
  return true
}

function isCompleteList(list, level) {
  if (!Array.isArray(list)) return false
  for (var i = 0; i < list.length; i++) {
    if (!isCompleteNode(list[i], level || 0)) return false
  }
  return true
}

function looksLikeOurFile(rawText) {
  var parsed
  try {
    parsed = JSON.parse(String(rawText === undefined || rawText === null ? "" : rawText))
  } catch (e) {
    return false
  }
  if (!isPlainObject(parsed)) return false
  if (!Array.isArray(parsed.items) && !Array.isArray(parsed.bookmarks)) return false
  // The wrapper itself is not a node: normalising it would read its `version`
  // as a type and fail, which is the cheap way to tell a state from an entry.
  if (isPlainObject(normalizeNode(parsed, 0, {}))) return false
  return isCompleteList(itemsOf(parsed), 0)
}

function argvFor(node, home) {
  var normalized = normalizeEntry(node)
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

// A dated filename, so a second export never silently overwrites the first one
// and "which one is mine" is answered by the name rather than by remembering.
function exportName(home, when) {
  var stamp = String(when === undefined || when === null ? "" : when)
  var day = /^\d{4}-\d{2}-\d{2}$/.test(stamp) ? stamp : "export"
  return String(home === undefined || home === null ? "" : home) + "/omarchy-bookmarks-" + day + ".json"
}

// The glyph a row leads with. A folder opens and closes the way it looks, which
// is one glyph doing two jobs instead of a chevron that has to sit in its own
// column; the panel draws the chevron separately when it wants one.
function kindGlyph(node, collapsed) {
  var raw = isPlainObject(node) ? node : {}
  var kind = normalizeKind(raw.kind)
  if (kind === "folder") return collapsed === true ? KIND_GLYPHS.folder : KIND_GLYPHS.folderOpen
  if (kind === "section") return KIND_GLYPHS.section
  return typeGlyph(raw.type)
}

function chevronFor(collapsed) {
  return collapsed === true ? CHEVRON_RIGHT : CHEVRON_DOWN
}

// Mirrors BookmarkItem.qml's decision about which renderer the icon field
// deserves, so a saved bookmark previews the same way here.
function iconKind(node) {
  var raw = isPlainObject(node) ? node : {}
  if (raw.kind !== undefined && normalizeKind(raw.kind) !== "bookmark") {
    return isIconGlyph(raw.icon) ? "glyph" : "none"
  }
  var normalized = normalizeEntry(raw)
  if (!normalized) return "none"
  if (isIconGlyph(normalized.icon)) return "glyph"
  if (isDesktopId(normalized.icon)) return "app"
  return "none"
}

function labelFor(node) {
  var raw = isPlainObject(node) ? normalizeNode(node, 0, {}) : null
  return raw ? raw.label : ""
}

function typeFor(node) {
  var raw = isPlainObject(node) ? normalizeNode(node, 0, {}) : null
  return raw && raw.kind === "bookmark" ? raw.type : ""
}

function targetFor(node) {
  var raw = isPlainObject(node) ? normalizeNode(node, 0, {}) : null
  return raw && raw.kind === "bookmark" ? raw.target : ""
}

function idFor(node) {
  var raw = isPlainObject(node) ? normalizeNode(node, 0, {}) : null
  return raw ? raw.id : ""
}

function pinnedFor(node) {
  var raw = isPlainObject(node) ? normalizeNode(node, 0, {}) : null
  return !!raw && raw.kind === "bookmark" && raw.pinned === true
}

// Local stand-in for qs.Commons Util.isPlainObject, so this file stays
// importable (and testable) outside a QML engine.
function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// The fields of `over` laid on a copy of `under`, for the keys `over` has. The
// fields that describe what a row *is* — id, kind, and a folder's children —
// are deliberately not merged: the patch says what to change, and a caller that
// wants to change the kind of a row says so, but nobody renames a bookmark by
// handing over its id and expecting it to survive a round trip through here.
var PATCHABLE = ["type", "label", "target", "icon", "pinned", "childCount"]

function patchNode(under, over) {
  var merged = {}
  var i
  for (i = 0; i < PATCHABLE.length; i++) {
    if (under && Object.prototype.hasOwnProperty.call(under, PATCHABLE[i])) {
      merged[PATCHABLE[i]] = under[PATCHABLE[i]]
    }
  }
  for (i = 0; i < PATCHABLE.length; i++) {
    if (Object.prototype.hasOwnProperty.call(over, PATCHABLE[i])) {
      merged[PATCHABLE[i]] = over[PATCHABLE[i]]
    }
  }
  merged.kind = Object.prototype.hasOwnProperty.call(over, "kind")
    ? over.kind
    : (under ? under.kind : undefined)
  return merged
}
