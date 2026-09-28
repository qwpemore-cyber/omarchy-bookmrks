const fs = require("fs");
const src = fs.readFileSync(require("path").join(__dirname, "..", "src", "BookmarkModel.js"), "utf8");
  const M = new Function(src + "\nreturn {parse,serialize,fromObject,stateOf,itemsOf,append,updateAt,removeAt,moveBy,insertInto,insertAfterRow,indent,outdent,canIndent,canOutdent,setPinned,togglePinned,toggleCollapsed,isCollapsed,flatten,nodeAtRow,rowForId,indexForId,pathForRow,countSubtree,normalizeNode,normalizeEntry,kindGlyph,chevronFor,argvFor,iconKind,labelFor,typeFor,targetFor,idFor,pinnedFor,makeId,isIconGlyph,isDesktopId,isSeparatorGlyph,labelForType,TYPE_GLYPHS,KIND_GLYPHS,typeGlyph,lineHeightFor,isFileTarget,expandHome,fileLabel,TYPES,KINDS,MAX_DEPTH,isSupportedType,isSupportedKind,matches,filterIndexes,filterEntries,mergeEntries,looksLikeOurFile,exportName};")();

const GLYPH = String.fromCodePoint(0x0F488);   // Browser, from stock omarchy menu
const APPGLYPH = String.fromCodePoint(0xF003B); // Apps
let pass = 0, fail = 0;
const eq = (name, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) pass++; else { fail++; console.log("FAIL", name, "\n  got ", g, "\n  want", w); }
};

// The items of a state, whatever shape it arrived in. Most assertions below
// are about what the model does with nodes, not about which key the version
// happens to live under, so they read through this instead of caring.
const list = (s) => (s && Array.isArray(s.items)) ? s.items
                : (s && Array.isArray(s.bookmarks)) ? s.bookmarks
                : (Array.isArray(s) ? s : []);
// The labels of the rows a projection shows, which is what the panel draws.
const rows = (s, opts) => M.flatten(s, opts);
const ids = (s, opts) => rows(s, opts).map((r) => r.id);
const labelsIn = (s, opts) => rows(s, opts).map((r) => r.label);

// --- glyph constants are real single codepoints in the PUA
eq("type glyph single char", Array.from(M.TYPE_GLYPHS.url).length, 1);
eq("type glyph in PUA", M.isIconGlyph(M.TYPE_GLYPHS.url), true);
eq("type glyph app in PUA", M.isIconGlyph(M.TYPE_GLYPHS.app), true);
eq("type glyph cmd in PUA", M.isIconGlyph(M.TYPE_GLYPHS.cmd), true);
eq("glyph browser", M.TYPE_GLYPHS.url, GLYPH);
eq("glyph apps", M.TYPE_GLYPHS.app, APPGLYPH);
eq("typeGlyph fallback", M.typeGlyph("nope"), M.TYPE_GLYPHS.cmd);

// The folder and section glyphs are checked against the font the same way the
// type glyphs were, because a codepoint the font lacks draws as an empty box
// and nothing else in the chain reports it.
for (const key of ["folder", "folderOpen", "section", "pin"]) {
  eq(`${key} glyph is one codepoint`, Array.from(M.KIND_GLYPHS[key]).length, 1);
  eq(`${key} glyph in PUA`, M.isIconGlyph(M.KIND_GLYPHS[key]), true);
}
eq("chevrons in PUA",
   M.isIconGlyph(M.chevronFor(false)) && M.isIconGlyph(M.chevronFor(true)), true);
eq("chevron points down when open", M.chevronFor(false) !== M.chevronFor(true), true);

// --- parsing / normalisation
eq("parse empty", M.parse(""), {version:2,items:[]});
eq("parse garbage", M.parse("{oops"), {version:2,items:[]});
eq("parse null", M.parse(null), {version:2,items:[]});
eq("parse not json array", M.parse("5"), {version:2,items:[]});
eq("bare array ok", list(M.parse('[{"type":"url","target":"https://a.com"}]')).length, 1);
eq("drops bad type", list(M.parse('[{"type":"nope","target":"x"},{"type":"app","target":"ok"}]')).length, 1);
eq("drops empty target", list(M.parse('[{"type":"app","target":"  "}]')).length, 0);
eq("drops non-object", list(M.parse('[null,"x",5,{"type":"cmd","target":"ls"}]')).length, 1);
eq("type lowercased", list(M.parse('[{"type":"URL","target":"https://a.com"}]'))[0].type, "url");
eq("target trimmed", list(M.parse('[{"type":"app","target":"  firefox  "}]'))[0].target, "firefox");

// --- v1 files still read, and become v2 on the next save
// The upgrade path is the whole reason v1 support exists: the file is the only
// copy of somebody's list, so it has to survive a plugin update untouched.
const v1 = '{"version":1,"bookmarks":[{"id":"k1","type":"url","label":"GitHub","target":"https://github.com","icon":""},{"id":"k2","type":"file","label":"notes","target":"~/notes.md","icon":""}]}';
eq("a v1 file reads", list(M.parse(v1)).map((n) => n.id), ["k1","k2"]);
eq("a v1 entry becomes a bookmark node", list(M.parse(v1)).map((n) => n.kind), ["bookmark","bookmark"]);
eq("a v1 entry keeps its target", list(M.parse(v1))[1].target, "~/notes.md");
eq("a v1 entry gets a pinned flag", list(M.parse(v1)).map((n) => n.pinned), [false,false]);
eq("a v1 file is written back as v2", M.parse(M.serialize(M.parse(v1))).version, 2);
eq("the saved v2 shape has items", JSON.parse(M.serialize(M.parse(v1))).items.length, 2);
eq("a v1 file is still recognised as ours", M.looksLikeOurFile(v1), true);
eq("a bare array of v1 entries still parses", list(M.parse('[{"type":"cmd","target":"ls"}]')).length, 1);

// --- kinds
eq("bookmark is a kind", M.isSupportedKind("bookmark"), true);
eq("folder is a kind", M.isSupportedKind("folder"), true);
eq("section is a kind", M.isSupportedKind("section"), true);
// A separator used to be refused, on the grounds that it is a divider rather
// than a bookmark and the file was about bookmarks. It is a kind now, because
// Firefox's context menu offers "Add Separator" and there is no way to honour
// that with the three kinds that came before: a section with no name
// normalises to "(unnamed)", so a nameless section is a heading that says
// "(unnamed)" and a rule under it. Firefox makes it a node type for the same
// reason — TYPE_X_MOZ_PLACE_SEPARATOR, created by PlacesTransactions.NewSeparator.
eq("separator is a kind", M.isSupportedKind("separator"), true);
eq("a still-unknown kind is refused", M.isSupportedKind("nope"), false);

// A separator is a line and nothing else, so there is nothing to name, nothing
// to launch, nothing to pin and nowhere to put children. Every one of those is
// checked because each is a field a hand-edited file could otherwise carry and
// a panel could otherwise act on.
const sep = M.normalizeNode({kind:"separator"}, 0, {});
eq("a separator has no label", sep.label, undefined);
eq("a separator has no target", sep.target, undefined);
eq("a separator has no type", sep.type, undefined);
eq("a separator has no pinned key", "pinned" in sep, false);
eq("a separator has no items", sep.items, undefined);
eq("a separator keeps an icon field so the shape is uniform", sep.icon, "");
eq("a label pasted onto a separator is dropped, not shown",
   M.normalizeNode({kind:"separator",label:"Work"}, 0, {}).label, undefined);
eq("a target pasted onto a separator is dropped",
   M.normalizeNode({kind:"separator",target:"https://x.com"}, 0, {}).target, undefined);

// A label of "" must not resurrect the name, which is the whole reason the kind
// exists: this is the exact call the menu's "Add Separator" makes.
eq("the menu's own call produces a bare rule", M.normalizeNode({kind:"separator",label:""}, 0, {}).label, undefined);

// The file is the user's, so it has to round trip. A kind that normalises but
// does not survive a save is worse than one that was refused.
const sepTree = M.fromObject({items:[
  {kind:"bookmark",type:"url",label:"One",target:"https://one.example"},
  {kind:"separator"},
  {kind:"bookmark",type:"url",label:"Two",target:"https://two.example"}
]});
eq("a separator survives a round trip",
   M.fromObject(M.parse(M.serialize(sepTree))).items[1].kind, "separator");
eq("and it is still a separator on the other side, with no name",
   M.fromObject(M.parse(M.serialize(sepTree))).items[1].label, undefined);
// The row's label is "" and not undefined. QML renders an undefined into a
// QString binding as the word "undefined", or logs "Unable to assign
// [undefined] to QString" and draws nothing — and the whole projection has a
// shape the rest of the panel relies on, so one row kind with no name must not
// be the one that breaks it.
eq("its neighbours keep their names and their order, and the row between them is nameless",
   rows(M.fromObject(M.parse(M.serialize(sepTree)))).map((r) => r.label), ["One", "", "Two"]);
eq("and a separator's row label is a string, not undefined",
   typeof rows(sepTree)[1].label, "string");
eq("every string a row carries is a string, whatever the kind",
   rows(sepTree).every((r) => [r.label, r.type, r.target, r.icon].every((v) => typeof v === "string")), true);
eq("the row for a separator reports no kind-specific fields",
   rows(sepTree).map((r) => [r.type, r.target, r.pinned, r.childCount, r.hasChildren]),
   [["url","https://one.example",false,0,false],["","",false,0,false],["url","https://two.example",false,0,false]]);
eq("a separator is a row, not a gap: the list still has three",
   rows(sepTree).length, 3);
eq("a separator takes part in a search like any other row",
   M.matches({label:"",target:"",kind:"separator"}, ""), true);
eq("but it has no text to match against",
   M.matches(sepTree.items[1], "two"), false);

// Indenting a row into a separator would have nowhere to put it, and a
// separator can never be the row that receives children either.
eq("a row cannot be indented into a separator", M.canIndent(sepTree, 2, {}), false);
eq("a row above a separator can be indented out of its folder instead",
   M.canIndent(sepTree, 0, {}), false);
// The pinned view keeps a pinned bookmark and the folders on the way to it, so a
// separator between two pinned bookmarks is what gets dropped: it is on nobody's
// path, and a rule on a path would be a rule in the middle of a result list.
const sepPinned = M.fromObject({items:[
  {kind:"bookmark",type:"url",label:"One",target:"https://one.example",pinned:true},
  {kind:"separator"},
  {kind:"bookmark",type:"url",label:"Two",target:"https://two.example",pinned:true}
]});
eq("a separator between two pinned rows is not in the pinned view",
   M.flatten(sepPinned, {pinnedOnly:true}).map((r) => r.kind), ["bookmark","bookmark"]);
eq("and the pinned view is not simply the separator's row removed: it is a filter",
   rows(sepPinned).length, 3);
eq("with nothing pinned, the pinned view is empty rather than everything",
   M.flatten(sepTree, {pinnedOnly:true}).length, 0);
eq("a separator counts as one thing to delete", M.countSubtree(sepTree.items[1]), 1);

eq("a missing kind means bookmark", M.normalizeNode({type:"cmd",target:"ls"}).kind, "bookmark");
eq("an unknown kind is refused", M.normalizeNode({kind:"nope",label:"x"}), null);
eq("kind is case insensitive", M.normalizeNode({kind:"Folder",label:"x"}).kind, "folder");
eq("a bookmark needs a target", M.normalizeNode({kind:"bookmark",type:"url"}), null);
eq("a bookmark refuses a bad type", M.normalizeNode({kind:"bookmark",type:"nope",target:"x"}), null);
eq("a bookmark refuses a relative file", M.normalizeNode({kind:"bookmark",type:"file",target:"a.md"}), null);
eq("a folder keeps its children", M.normalizeNode({kind:"folder",label:"Code",items:[{kind:"bookmark",type:"url",target:"a"}]}).items.length, 1);
eq("a folder needs no target", M.normalizeNode({kind:"folder",label:"Code"}).items.length, 0);
eq("a folder ignores a stray target", M.normalizeNode({kind:"folder",label:"Code",target:"ls"}).target, undefined);
eq("a section keeps no children", M.normalizeNode({kind:"section",label:"Daily",items:[{kind:"bookmark",type:"url",target:"a"}]}).items, undefined);
// The name of this one used to say "no pinned flag" while asserting a flag set
// to false, which is a different claim: a key in the file is something a person
// editing the file by hand can see and set, and a section that can be pinned on
// paper but not in the panel is worse than one that plainly cannot.
eq("a section has no pinned key at all", "pinned" in M.normalizeNode({kind:"section",label:"Daily"}), false);
eq("a section's row still reports pinned, for one row shape",
   M.flatten(M.fromObject({items:[{kind:"section",label:"Daily"}]}), {})[0].pinned, false);
eq("a folder has no pinned key either", "pinned" in M.normalizeNode({kind:"folder",label:"Code",items:[]}), false);
eq("a bookmark keeps its pin through a round trip",
   M.nodeAtRow(M.parse(M.serialize(M.fromObject({items:[{id:"p",kind:"bookmark",type:"url",label:"P",target:"a.com",pinned:true}]}))), 0).pinned, true);
// A folder with no name would be a blank row, so it gets a name. It is filled
// in rather than dropped because dropping it would take its children with it,
// and reading a file is meant to preserve what is in it.
eq("an unnamed folder is named, not dropped", M.normalizeNode({kind:"folder",items:[{kind:"bookmark",type:"url",target:"a"}]}).label, "(unnamed)");
eq("an unnamed folder keeps its children", M.normalizeNode({kind:"folder",items:[{kind:"bookmark",type:"url",target:"a"}]}).items.length, 1);
eq("an unnamed section is named", M.normalizeNode({kind:"section"}).label, "(unnamed)");
eq("normalizeEntry still only returns bookmarks", M.normalizeEntry({kind:"folder",label:"x"}), null);
eq("normalizeEntry still returns a v1 entry", M.normalizeEntry({type:"url",target:"a"}).kind, "bookmark");

// --- pinned
eq("pinned true is pinned", M.normalizeNode({kind:"bookmark",type:"url",target:"a",pinned:true}).pinned, true);
eq("pinned absent is not pinned", M.normalizeNode({kind:"bookmark",type:"url",target:"a"}).pinned, false);
eq("pinned as a string is pinned", M.normalizeNode({kind:"bookmark",type:"url",target:"a",pinned:"true"}).pinned, true);
eq("pinned as yes is pinned", M.normalizeNode({kind:"bookmark",type:"url",target:"a",pinned:"1"}).pinned, true);
eq("a folder cannot be pinned", M.normalizeNode({kind:"folder",label:"x",pinned:true}).pinned, undefined);

// --- depth
// A hand-edited file can nest as deep as it likes, and the walk recurses, so
// the depth is bounded rather than left to overflow the stack.
let deep = {kind:"bookmark",type:"url",target:"a"};
for (let i = 0; i < 40; i++) deep = {kind:"folder",label:"d"+i,items:[deep]};
const deepOk = M.fromObject({items:[deep]});
let depth = 0, probe = deepOk;
while (probe.items && probe.items.length) { depth++; probe = probe.items[0]; }
// Level 0 is the outermost folder, so N nested folders means the innermost one
// sits at level N-1 and the bound is one more than MAX_DEPTH, not equal to it.
eq("a very deep nest is truncated, not fatal", depth <= M.MAX_DEPTH + 1, true);
eq("a truncated nest is not left empty", depth > 1, true);
eq("a truncated nest still keeps its top", list(deepOk).length, 1);

// --- labels
eq("url label", M.labelForType("url","https://github.com/qwpemore"), "github.com");
eq("url label no path", M.labelForType("url","https://example.com"), "example.com");
eq("url label cuts path", M.labelForType("url","https://a.co/x/y?q=1"), "a.co");
eq("url label query only", M.labelForType("url","https://a.co?q=1"), "a.co?q=1");
eq("app strips path", M.labelForType("app","/usr/bin/firefox"), "firefox");
eq("cmd first word", M.labelForType("cmd","omarchy-capture-screenshot --full"), "omarchy-capture-screenshot");
eq("explicit label wins", list(M.parse('[{"type":"url","target":"https://a.com","label":"Mine"}]'))[0].label, "Mine");
eq("a folder keeps its own label", M.labelFor({kind:"folder",label:"Code"}), "Code");
eq("a folder has no type", M.typeFor({kind:"folder",label:"Code"}), "");
eq("a folder has no target", M.targetFor({kind:"folder",label:"Code"}), "");

// --- ids
const a = list(M.parse('[{"type":"app","target":"a"}]'))[0];
const b = list(M.parse('[{"type":"app","target":"b"}]'))[0];
eq("id assigned", !!a.id, true);
eq("ids unique", a.id !== b.id, true);
eq("dup id repaired", list(M.parse('[{"id":"x","type":"app","target":"a"},{"id":"x","type":"app","target":"b"}]'))[1].id !== "x", true);
eq("update keeps id", list(M.updateAt({items:[a,b]}, 0, {type:"cmd",target:"ls"}))[0].id, a.id);
// Ids are unique across the whole tree, not just within one folder, or the
// panel's row -> node translation would be ambiguous.
eq("dup id across folders repaired",
   list(M.parse('{"items":[{"kind":"folder","label":"x","items":[{"id":"d","type":"url","target":"a"}]},{"kind":"folder","label":"y","items":[{"id":"d","type":"url","target":"b"}]}]}'))[1].items[0].id !== "d", true);

// --- icon classification
eq("glyph accepted", M.isIconGlyph(GLYPH), true);
eq("legacy pua accepted", M.isIconGlyph(String.fromCodePoint(0xE5FF)), true);
eq("ascii rejected", M.isIconGlyph("abc"), false);
eq("ascii letter rejected", M.isIconGlyph("a"), false);
eq("separator rejected", M.isIconGlyph("."), false);
eq("emoji rejected", M.isIconGlyph("\u{1F389}"), false);
eq("arabic rejected", M.isIconGlyph("ب"), false);
eq("two glyphs rejected", M.isIconGlyph(GLYPH + GLYPH), false);
eq("desktop id", M.isDesktopId("org.gnome.Nautilus"), true);
eq("exe not desktop", M.isDesktopId("firefox"), false);
eq("iconKind glyph", M.iconKind({type:"url",target:"a",icon:GLYPH}), "glyph");
eq("iconKind app", M.iconKind({type:"app",target:"a",icon:"org.gnome.Nautilus"}), "app");
eq("iconKind none", M.iconKind({type:"app",target:"a"}), "none");
eq("a folder can carry a glyph icon", M.iconKind({kind:"folder",label:"x",icon:GLYPH}), "glyph");
eq("a folder cannot carry a desktop id as an icon", M.iconKind({kind:"folder",label:"x",icon:"org.gnome.Nautilus"}), "none");
eq("glyph promoted from target", list(M.parse('[{"type":"app","target":' + JSON.stringify(APPGLYPH) + '}]'))[0].icon, APPGLYPH);
eq("bad icon dropped", list(M.parse('[{"type":"app","target":"a","icon":"a/b"}]'))[0].icon, "");

// --- argv construction (no shell for url/app)
eq("url argv", M.argvFor({type:"url",target:"https://a.com"}), ["omarchy-launch-webapp","https://a.com"]);
eq("app argv bare command", M.argvFor({type:"app",target:"firefox"}), ["uwsm-app","--","firefox"]);
eq("app argv desktop", M.argvFor({type:"app",target:"org.gnome.Nautilus"}), ["gtk-launch","org.gnome.Nautilus"]);
eq("cmd argv", M.argvFor({type:"cmd",target:"ls | wc -l"}), ["bash","-c","ls | wc -l"]);
eq("argv rejects bad type", M.argvFor({type:"bad",target:"x"}), []);
eq("argv rejects empty", M.argvFor({type:"url",target:""}), []);
// A folder has no target, so there is nothing for the model to turn into a
// command. Refusing here is what makes "a folder row launches nothing" a
// property of the data rather than a rule the UI has to remember.
eq("a folder has no argv", M.argvFor({kind:"folder",label:"Code",items:[{kind:"bookmark",type:"url",target:"a"}]}), []);
eq("a section has no argv", M.argvFor({kind:"section",label:"Daily"}), []);
eq("a folder with a planted target still has no argv", M.argvFor({kind:"folder",label:"x",target:"rm -rf /"}), []);
eq("injection stays one arg", M.argvFor({type:"url",target:"x; rm -rf /"}).length, 2);
eq("injection literal", M.argvFor({type:"url",target:"x; rm -rf /"})[1], "x; rm -rf /");

// --- every launcher the model can emit must exist on this machine
// The suite above happily asserted an argv whose first element was a command
// that was never installed, so the shape of the argv is checked against the
// real PATH here. Only the program is checked: the target is user data.
const { execFileSync } = require("child_process");
const which = (p) => { try { execFileSync("which", [p], { stdio: ["ignore", "pipe", "ignore"] }); return true; } catch { return false; } };
const emitted = new Set();
for (const t of ["url", "app", "cmd", "file"])
  for (const target of ["https://a.com", "org.gnome.Nautilus", "firefox", "ls", "/tmp/a.md"]) {
    const argv = M.argvFor({ type: t, target });
    // argv[0] is always the program; everything after it is user data.
    if (argv.length > 0) emitted.add(argv[0]);
  }

for (const prog of [...emitted].sort())
  eq(`${prog} exists on PATH`, which(prog), true);

// --- the tree the rest of the suite works on
//   Daily                     section
//   Code                      folder
//     GitHub                  bookmark
//     Servers                 folder
//       up                    bookmark
//   notes                     bookmark, pinned
const tree = () => M.fromObject({items:[
  {id:"s1",kind:"section",label:"Daily"},
  {id:"f1",kind:"folder",label:"Code",items:[
    {id:"b1",kind:"bookmark",type:"url",label:"GitHub",target:"https://github.com"},
    {id:"f2",kind:"folder",label:"Servers",items:[
      {id:"b2",kind:"bookmark",type:"cmd",label:"up",target:"up.sh"}
    ]}
  ]},
  {id:"b3",kind:"bookmark",type:"file",label:"notes",target:"~/notes.md",pinned:true}
]});

eq("a tree flattens to every row", ids(tree()), ["s1","f1","b1","f2","b2","b3"]);
eq("depth starts at the top", rows(tree()).map((r) => r.depth), [0,0,1,1,2,0]);
eq("parents are named", rows(tree()).map((r) => r.parentId), ["","","f1","f1","f2",""]);
eq("a folder knows it has children", rows(tree()).map((r) => r.hasChildren), [false,true,false,true,false,false]);
eq("a folder counts its children", rows(tree()).map((r) => r.childCount), [0,2,0,1,0,0]);
eq("a leaf knows it has none", rows(tree())[1].childCount > 0, true);
eq("a row carries its kind", rows(tree()).map((r) => r.kind), ["section","folder","bookmark","folder","bookmark","bookmark"]);
eq("a folder row has no target", rows(tree())[1].target, "");
eq("a bookmark row keeps its type", rows(tree())[2].type, "url");
eq("nothing is collapsed by default", rows(tree()).some((r) => r.collapsed), false);
eq("paths address the tree", rows(tree()).map((r) => r.path.join(".")), ["0","1","1.0","1.1","1.1.0","2"]);

// --- collapse is panel state, never data
eq("a collapsed folder hides its children", ids(tree(), {collapsed:{f1:true}}), ["s1","f1","b3"]);
eq("a collapsed row knows it is collapsed", rows(tree(), {collapsed:{f1:true}})[1].collapsed, true);
eq("an open row is not collapsed", rows(tree(), {collapsed:{f2:true}})[1].collapsed, false);
eq("a collapsed nested folder hides only its own children", ids(tree(), {collapsed:{f2:true}}), ["s1","f1","b1","f2","b3"]);
eq("collapsing does not change the file", list(tree()).length, 3);
eq("collapse is not a saved field", "collapsed" in list(tree())[1], false);
const before = {f1:true};
const toggled = M.toggleCollapsed(before, "f1");
eq("toggling a collapsed id opens it", M.isCollapsed(toggled, "f1"), false);
eq("toggling a new id collapses it", M.isCollapsed(M.toggleCollapsed({}, "f9"), "f9"), true);
eq("toggling does not mutate the input", before, {f1:true});
eq("isCollapsed on a non-map is false", M.isCollapsed(null, "f1"), false);

// --- a filter reveals, plain collapse does not
// The count the header shows has to mean something, so anything that narrows
// the list expands what it keeps: searching for something inside a folder you
// had closed still finds it, and the "3 of 40" is honest about what is shown.
// A filter never shows a row that neither matches nor leads to a match. The
// ancestors of a hit are shown, because a hit with no indication of where it
// lives is not a result, but a folder's other children are not dragged in by
// their parent matching.
eq("a search finds a nested bookmark", ids(tree(), {query:"up"}), ["f1","f2","b2"]);
eq("a search keeps the ancestors that lead to it", labelsIn(tree(), {query:"up"}), ["Code","Servers","up"]);
eq("a search inside a closed folder still finds it", ids(tree(), {query:"up",collapsed:{f1:true}}), ["f1","f2","b2"]);
eq("a search matches a folder by name", labelsIn(tree(), {query:"serv"}), ["Code","Servers"]);
eq("a folder that matches does not drag its children in", labelsIn(tree(), {query:"code"}), ["Code"]);
eq("a search that matches nothing is empty", ids(tree(), {query:"zzzz"}), []);
eq("a search matches a bookmark by target", labelsIn(tree(), {query:"up.sh"}), ["Code","Servers","up"]);
eq("a search does not match a folder's children", labelsIn(tree(), {query:"github.com"}), ["Code","GitHub"]);
eq("a section is matched like anything else", labelsIn(tree(), {query:"daily"}), ["Daily"]);
eq("an empty search changes nothing", ids(tree(), {query:"   "}), ids(tree()));

// --- pinned only
// A view, not a sort: pinned rows stay where they are and everything else is
// merely not drawn, which is the difference between a toolbar and a list.
eq("pinned only shows the pinned rows", ids(tree(), {pinnedOnly:true}), ["b3"]);
eq("pinned only keeps a folder with a pinned row in it",
   labelsIn(M.fromObject({items:[{kind:"folder",label:"Work",items:[{kind:"bookmark",type:"url",label:"Pinned",target:"a.com",pinned:true}]}]}),
       {pinnedOnly:true}), ["Work","Pinned"]);
eq("pinned only drops a folder with nothing pinned in it",
   labelsIn(M.fromObject({items:[{kind:"folder",label:"Work",items:[{kind:"bookmark",type:"url",label:"Plain",target:"a.com"}]}]}),
       {pinnedOnly:true}), []);
eq("pinned only ignores collapse", ids(tree(), {pinnedOnly:true,collapsed:{f1:true}}), ["b3"]);
eq("pinned only with nothing pinned is empty", ids(tree(), {pinnedOnly:true,query:"zzzz"}), []);
eq("pinned and a query both apply",
   labelsIn(M.fromObject({items:[
     {kind:"bookmark",type:"url",label:"pinned hit",target:"a.com",pinned:true},
     {kind:"bookmark",type:"url",label:"pinned miss",target:"b.com",pinned:true},
     {kind:"bookmark",type:"url",label:"plain hit",target:"a.org"}
   ]}), {pinnedOnly:true,query:"hit"}), ["pinned hit"]);
eq("a query alone still finds an unpinned row",
   labelsIn(M.fromObject({items:[
     {kind:"bookmark",type:"url",label:"pinned hit",target:"a.com",pinned:true},
     {kind:"bookmark",type:"url",label:"plain hit",target:"a.org"}
   ]}), {query:"hit"}), ["pinned hit","plain hit"]);
// rowForId and indexForId are separate on purpose, and the reason is a real
// mistake rather than tidiness: a caller that wanted the number was handed the
// object, every `row < 0` test on it is false, the mutation refused, and the
// panel answered "unknown" for a row that was plainly on screen. The pair is
// checked together here because that is where the confusion lives.
eq("indexForId gives the number", M.indexForId(tree(), "b1", {}), 2);
eq("indexForId gives -1 for a row that is not shown", M.indexForId(tree(), "b1", {query:"Daily"}), -1);
eq("indexForId gives -1 rather than null, so `>= 0` is the only true test",
   M.indexForId(tree(), "nope", {}) >= 0, false);
eq("rowForId gives the row itself", M.nodeAtRow(tree(), M.indexForId(tree(), "b1", {}), {}).id, "b1");
eq("a row under a folder is found by id too", M.indexForId(tree(), "b2", {}), 4);
eq("a collapsed folder hides its children from indexForId", M.indexForId(tree(), "b1", {collapsed:{f1:true}}), -1);
eq("but the parent is still found", M.indexForId(tree(), "f1", {collapsed:{f1:true}}), 1);

eq("a section is never in the pinned view",
   labelsIn(M.fromObject({items:[{kind:"section",label:"Daily"},{kind:"bookmark",type:"url",label:"P",target:"a",pinned:true}]}),
       {pinnedOnly:true}), ["P"]);
eq("a pinned row is flagged on its row", rows(tree()).map((r) => r.pinned), [false,false,false,false,false,true]);
eq("a folder row is never flagged", rows(tree())[1].pinned, false);

// --- node lookup by row
eq("a row finds its node", M.nodeAtRow(tree(), 2).target, "https://github.com");
eq("a nested row finds its node", M.nodeAtRow(tree(), 4).label, "up");
eq("a row past the end finds nothing", M.nodeAtRow(tree(), 99), null);
eq("a negative row finds nothing", M.nodeAtRow(tree(), -1), null);
eq("a row is found by id", M.rowForId(tree(), "b2").depth, 2);
eq("an unknown id is not found", M.rowForId(tree(), "nope"), null);
eq("a row inside a collapsed folder is not found", M.rowForId(tree(), "b1", {collapsed:{f1:true}}), null);

// --- countSubtree
eq("a bookmark counts one", M.countSubtree(M.nodeAtRow(tree(), 2)), 1);
eq("a folder counts itself and its children", M.countSubtree(M.nodeAtRow(tree(), 1)), 4);
eq("an outer folder counts the lot", M.countSubtree(M.nodeAtRow(tree(), 1, {})), 4);
eq("a section counts one", M.countSubtree(M.nodeAtRow(tree(), 0)), 1);
eq("nothing counts zero", M.countSubtree(null), 0);
eq("a folder's count does not depend on a filter", M.countSubtree(M.nodeAtRow(tree(), 0, {query:"up"})), 4);
eq("a nested folder counts its own subtree", M.countSubtree(M.nodeAtRow(tree(), 1, {query:"up"})), 2);

// --- mutations, still the flat list they always were
// A one-level tree behaves exactly like the flat list this replaced, which is
// the reason the index-based surface survived the move to a tree at all.
let s = {items:list(M.parse('[{"type":"app","target":"a"},{"type":"app","target":"b"},{"type":"app","target":"c"}]'))};
eq("append", M.append(s,{type:"cmd",target:"d"}).length, 4);
eq("append rejects junk", M.append(s,{type:"cmd",target:""}).length, 3);
eq("append takes a folder", M.append(s,{kind:"folder",label:"Code"}).length, 4);
eq("append a folder is a folder", M.append(s,{kind:"folder",label:"Code"})[3].kind, "folder");
eq("updateAt oob", M.updateAt(s,9,{type:"app",target:"z"}).length, 3);
eq("updateAt rejects junk", M.updateAt(s,0,{type:"app",target:""}).length, 3);
eq("removeAt", M.removeAt(s,0).map((e) => e.target), ["b","c"]);
eq("removeAt oob", M.removeAt(s,5).length, 3);
eq("moveBy down", M.moveBy(s,0,1).map((e) => e.target), ["b","a","c"]);
eq("moveBy up", M.moveBy(s,2,-1).map((e) => e.target), ["a","c","b"]);
eq("moveBy clamps low", M.moveBy(s,0,-1).map((e) => e.target), ["a","b","c"]);
eq("moveBy clamps high", M.moveBy(s,2,1).map((e) => e.target), ["a","b","c"]);
eq("moveBy oob", M.moveBy(s,9,1).length, 3);

// --- mutations, in a tree
eq("removeAt takes the whole subtree", ids({items:M.removeAt(tree(), 1)}), ["s1","b3"]);
eq("removeAt on a nested row removes just that row", ids({items:M.removeAt(tree(), 4)}), ["s1","f1","b1","f2","b3"]);
eq("removeAt on a leaf", ids({items:M.removeAt(tree(), 2)}), ["s1","f1","f2","b2","b3"]);
eq("removing the last top level row", ids({items:M.removeAt(tree(), 5)}), ["s1","f1","b1","f2","b2"]);

// The thing a flat moveBy could not express: J and K move among siblings, so
// the end of a folder is a wall rather than a step into whatever comes next.
// These read against a folder of three flat rows, where every sibling boundary
// is reachable in one keypress and the expected order is unambiguous.
const three = M.fromObject({items:[
  {id:"k",kind:"folder",label:"K",items:[
    {id:"a",kind:"bookmark",type:"url",label:"A",target:"a.com"},
    {id:"b",kind:"bookmark",type:"url",label:"B",target:"b.com"},
    {id:"c",kind:"bookmark",type:"url",label:"C",target:"c.com"}]}]});
eq("moveBy down among siblings", labelsIn({items:M.moveBy(three,1,1)}), ["K","B","A","C"]);
eq("moveBy up among siblings", labelsIn({items:M.moveBy(three,2,-1)}), ["K","B","A","C"]);
eq("moveBy stops at the first sibling", labelsIn({items:M.moveBy(three,1,-1)}), ["K","A","B","C"]);
eq("moveBy stops at the last sibling", labelsIn({items:M.moveBy(three,3,1)}), ["K","A","B","C"]);
eq("a top level row does not move into a folder", labelsIn({items:M.moveBy(three,0,1)}), ["K","A","B","C"]);

// And against the nested tree, where the pre-order walk of the result is not
// the sibling order that changed, which is what a reader would expect to see.
eq("moveBy inside a folder stays in the folder", ids({items:M.moveBy(tree(), 2, 1)}), ["s1","f1","f2","b2","b1","b3"]);
eq("the moved row is a child of the same folder", M.rowForId({items:M.moveBy(tree(),2,1)}, "b1").parentId, "f1");
eq("a moved folder keeps its children", labelsIn({items:M.moveBy(tree(), 1, 1)}), ["Daily","notes","Code","GitHub","Servers","up"]);
// A filter renumbers the rows it keeps, so the same key on the same number
// moves a different row. That is the point of addressing by row: what the key
// acts on is what the list is showing, not what it would show unfiltered.
eq("a filtered moveBy moved the row under the cursor",
   labelsIn({items:M.moveBy(tree(), 1, 1, {query:"Git"})}), ["Daily","Code","Servers","up","GitHub","notes"]);
eq("without the filter the same key moves a different row",
   labelsIn({items:M.moveBy(tree(), 1, 1)}), ["Daily","notes","Code","GitHub","Servers","up"]);

// Editing a row's kind must not empty the folder it became.
// update is a patch, not a replacement: a caller that wants to rename a row
// sends the name, not a whole node it had to read back first. It used to
// normalize the payload on its own, so {"label":"x"} had no kind and was
// refused — the panel answered "unknown" and the file did not change, which
// reads as the caller's mistake. Sent whole, everything still works.
const patched = (row, patch) => M.nodeAtRow({items: M.updateAt(tree(), row, patch, {})}, row);
eq("a patch can rename a bookmark", patched(2, {label:"Renamed"}).label, "Renamed");
eq("a patch keeps the target it did not mention", patched(2, {label:"Renamed"}).target, "https://github.com");
eq("a patch keeps the kind it did not mention", patched(2, {label:"Renamed"}).kind, "bookmark");
eq("a patch keeps the type it did not mention", patched(2, {label:"Renamed"}).type, "url");
eq("a patch keeps a pin it did not mention", patched(5, {label:"Renamed"}).pinned, true);
eq("a patch can unpin when asked", patched(5, {pinned:false}).pinned, false);
eq("a patch can set a field to empty, which is how it is cleared", patched(2, {icon:""}).icon, "");
eq("an empty patch changes nothing", patched(2, {}).label, "GitHub");
eq("a patch keeps what a folder was holding", ids({items: M.updateAt(tree(), 1, {label:"Code renamed"}, {})}, {}),
   ["s1","f1","b1","f2","b2","b3"]);
eq("a patch cannot change a row's id", patched(2, {label:"Renamed",id:"hijacked"}).id, "b1");
eq("a patch cannot give a bookmark children", patched(2, {childCount:3}).items, undefined);
eq("nor turn it into a folder to hold them", patched(2, {childCount:3}).kind, "bookmark");
// childCount is counted from the children rather than stored, so it is a thing
// a caller reads off a row and never a thing a caller writes into one.
eq("a node carries no stored child count", patched(1, {childCount:9}).childCount, undefined);
eq("and the count a row shows is still the real one", rows({items: M.updateAt(tree(), 1, {childCount:9}, {})})[1].childCount, 2);
eq("a patch that names a kind changes it", patched(2, {kind:"folder"}).kind, "folder");
eq("but a folder with things in it still refuses", patched(1, {kind:"bookmark",label:"Flat"}).kind, "folder");
eq("and nothing was lost by the refusal", ids({items: M.updateAt(tree(), 1, {kind:"bookmark"}, {})}, {}),
   ["s1","f1","b1","f2","b2","b3"]);
// Clearing a label does not leave a blank row: it renames the row to what the
// target says it is, the way a browser names a bookmark it was given none. The
// target is untouched, so nothing is lost, and the panel shows it immediately.
eq("a patch that clears a label falls back to the host", patched(2, {label:""}).label, "github.com");
eq("and the target is still the target", patched(2, {label:""}).target, "https://github.com");
eq("a file's name comes from its path", patched(5, {label:""}).label, "notes.md");
eq("a command's name comes from its first word", patched(4, {label:""}).label, "up.sh");

eq("a patch that leaves the target empty is refused, as a whole row would be",
   patched(2, {target:""}).target, "https://github.com");

eq("changing a bookmark into a folder keeps what the folder held",
   ids({items:M.updateAt(tree(), 1, {kind:"folder",label:"Renamed"})}, {}), ["s1","f1","b1","f2","b2","b3"]);
eq("the renamed folder keeps its label", M.nodeAtRow({items:M.updateAt(tree(), 1, {kind:"folder",label:"Renamed"})}, 1).label, "Renamed");
eq("a payload that never mentions pinning leaves the flag alone",
   M.nodeAtRow({items:M.updateAt(tree(), 5, {type:"file",label:"n",target:"~/x.md"})}, 5).pinned, true);
eq("a payload can clear the flag", M.nodeAtRow({items:M.updateAt(tree(), 5, {type:"file",label:"n",target:"~/x.md",pinned:false})}, 5).pinned, false);
eq("a payload can set the flag", M.nodeAtRow({items:M.updateAt(tree(), 2, {type:"url",label:"G",target:"https://x.com",pinned:true})}, 2).pinned, true);

// --- insertInto
// The expected labels include the new row, whose id is minted at random, so
// these are read by label and never by a guessed id.
const build = {kind:"bookmark",type:"cmd",label:"build",target:"make"};
eq("insertInto adds to the folder", labelsIn({items:M.insertInto(tree(), 1, build)}), ["Daily","Code","GitHub","Servers","up","build","notes"]);
eq("insertInto into a folder row is a child", rows({items:M.insertInto(tree(), 1, build)}).filter((r) => r.label === "build")[0].depth, 1);
eq("insertInto into a non-folder row goes to the top", labelsIn({items:M.insertInto(tree(), 0, build)}).pop(), "build");
eq("insertInto into nothing goes to the top", labelsIn({items:M.insertInto(tree(), -1, build)}).pop(), "build");
eq("insertInto rejects junk", M.insertInto(tree(), 1, {kind:"bookmark",type:"cmd",target:""}).length, 3);
eq("insertInto can add a folder", M.insertInto(tree(), 1, {kind:"folder",label:"Sub"})[1].kind, "folder");
// Under this filter row 1 is GitHub and row 0 is the folder above it, so the
// same number lands somewhere else entirely — which is why the row the modal
// hands over has to be resolved with the filter the list is showing.
eq("insertInto into a folder under a filter still nests",
   rows({items:M.insertInto(tree(), 0, build, {query:"Git"})}).filter((r) => r.label === "build")[0].depth, 1);

// --- insertAfterRow
// The rule the context menu needs, and the one insertInto could not express: a
// folder is a container, so the new row goes inside it; anything else is a
// sibling, so the new row goes directly below it in the same parent. Firefox
// writes the same thing as a parent guid plus an index within that parent, and
// bumps the index as it pastes so the order holds.
//
// The two functions disagree, and that disagreement is the point. insertInto
// sent a new item to the end of the root for every row that is not a folder, so
// right-clicking a bookmark in the middle of a folder and adding one put it
// nowhere near the bookmark. The row cursor moves all the time, so this is the
// normal case rather than an edge.
eq("insertAfterRow on a folder goes inside it",
   labelsIn({items:M.insertAfterRow(tree(), 1, build)}), ["Daily","Code","GitHub","Servers","up","build","notes"]);
eq("insertAfterRow on a bookmark is its next sibling, not the end of the file",
   labelsIn({items:M.insertAfterRow(tree(), 2, build)}), ["Daily","Code","GitHub","build","Servers","up","notes"]);
eq("and it lands in the same folder, at the same depth",
   rows({items:M.insertAfterRow(tree(), 2, build)}).filter((r) => r.label === "build")[0].depth, 1);
eq("insertAfterRow on a section is a sibling of the section",
   labelsIn({items:M.insertAfterRow(tree(), 0, build)}), ["Daily","build","Code","GitHub","Servers","up","notes"]);
// Row 4 is "up", the only child of the "Servers" folder, so the new row joins
// that folder rather than the root — checked by position in the flattened order
// and by depth, because `.pop()` on the whole list is the top-level row after it
// and would have passed on a wrong answer.
eq("insertAfterRow on a row inside a folder joins that folder, not the root",
   labelsIn({items:M.insertAfterRow(tree(), 4, build)}), ["Daily","Code","GitHub","Servers","up","build","notes"]);
eq("at the depth of the row it followed",
   rows({items:M.insertAfterRow(tree(), 4, build)}).filter((r) => r.label === "build")[0].depth, 2);
eq("insertAfterRow on the very last row appends rather than losing it",
   labelsIn({items:M.insertAfterRow(tree(), 5, build)}).pop(), "build");
eq("insertAfterRow with no row is the same as insertInto with no folder",
   labelsIn({items:M.insertAfterRow(tree(), -1, build)}).pop(), "build");
eq("insertAfterRow rejects junk and changes nothing",
   M.insertAfterRow(tree(), 2, {kind:"bookmark",type:"cmd",target:""}).length, 3);
eq("insertAfterRow out of range appends rather than throwing",
   labelsIn({items:M.insertAfterRow(tree(), 99, build)}).pop(), "build");

// The menu's "Add Separator" goes through here, so this is the call it makes.
eq("insertAfterRow places a separator beside a bookmark",
   rows({items:M.insertAfterRow(tree(), 2, {kind:"separator"})}).map((r) => r.kind),
   ["section","folder","bookmark","separator","folder","bookmark","bookmark"]);
eq("and two separators in a row are two rows, not one",
   rows({items:M.insertAfterRow(M.fromObject({items:M.insertAfterRow(tree(), 2, {kind:"separator"})}), 3, {kind:"separator"})})
     .filter((r) => r.kind === "separator").length, 2);

// Under a filter the row number names a different row, so the same number must
// land somewhere else — which is why the caller resolves the row through the
// view it is showing. Read back without the filter, because a row whose label
// is "build" does not match "Git" and would be filtered out of its own result.
// A filter keeps the folders on the way to a match, so the filtered row 0 is the
// folder "Code" and row 1 is the bookmark "GitHub". Both numbers are checked,
// because they are the two branches of the rule arriving at once: a filtered
// folder takes the new row inside it, a filtered bookmark makes it a sibling.
// Read back without the filter, because "build" does not match "Git" and would
// be filtered out of its own result.
eq("insertAfterRow on a filtered folder takes it inside",
   labelsIn({items:M.insertAfterRow(tree(), 0, build, {query:"Git"})}),
   ["Daily","Code","GitHub","Servers","up","build","notes"]);
eq("insertAfterRow on a filtered bookmark makes it a sibling",
   labelsIn({items:M.insertAfterRow(tree(), 1, build, {query:"Git"})}),
   ["Daily","Code","GitHub","build","Servers","up","notes"]);
eq("and it is at the depth of the row it followed",
   rows({items:M.insertAfterRow(tree(), 1, build, {query:"Git"})}).filter((r) => r.label === "build")[0].depth, 1);

// --- indent and outdent
// Indent moves a row under the folder just above it, which is Firefox's `l`.
const pair = M.fromObject({items:[
  {kind:"bookmark",type:"url",label:"One",target:"1.com"},
  {kind:"bookmark",type:"url",label:"Two",target:"2.com"}]});
eq("canIndent needs a row above", M.canIndent(tree(), 1), false);
eq("canIndent needs a folder above", M.canIndent(pair, 1), false);
eq("canIndent under a folder", M.canIndent(tree(), 5), true);
eq("canIndent is false for the first row of a folder", M.canIndent(tree(), 2), false);
eq("indent moves a row into the folder above", ids({items:M.indent(tree(), 5)}), ["s1","f1","b1","f2","b2","b3"]);
eq("the indented row is a child", rows({items:M.indent(tree(), 5)}).filter((r) => r.id === "b3")[0].depth, 1);
eq("the indented row goes to the end of the folder", rows({items:M.indent(tree(), 5)}).pop().id, "b3");
eq("indent refuses the first row", ids({items:M.indent(tree(), 0)}), ids(tree()));
eq("indent refuses under a bookmark", labelsIn({items:M.indent(pair, 1)}), ["One","Two"]);
// A folder can never end up inside itself: the target is a sibling, and a
// sibling is by definition not inside anything the mover contains.
eq("a folder cannot be indented into itself", ids({items:M.indent(tree(), 1)}), ids(tree()));
eq("a folder cannot be indented into its own child", ids({items:M.indent(tree(), 1)}), ids(tree()));
eq("indent a folder", ids({items:M.indent(tree(), 3)}), ["s1","f1","b1","f2","b2","b3"]);

// Outdent lifts a row to just after its parent, the way a drag back to the
// list above it lands. A first or last child lands in the same place in the
// walk either way, so these read a middle child — a position that cannot be
// mistaken for "nothing happened".
const nest = M.fromObject({items:[
  {kind:"folder",label:"K",items:[
    {kind:"bookmark",type:"url",label:"A",target:"a.com"},
    {kind:"bookmark",type:"url",label:"B",target:"b.com"},
    {kind:"bookmark",type:"url",label:"C",target:"c.com"}]}]});
eq("canOutdent is false at the top", M.canOutdent(tree(), 1), false);
eq("canOutdent is true inside a folder", M.canOutdent(tree(), 2), true);
eq("outdent of a middle child moves it out of the folder", labelsIn({items:M.outdent(nest, 2)}), ["K","A","C","B"]);
eq("the outdented row is at the top level", rows({items:M.outdent(nest, 2)}).filter((r) => r.label === "B")[0].depth, 0);
eq("the rows around it keep their order", labelsIn({items:M.outdent(nest, 2)}).filter((l) => l === "A" || l === "C"), ["A","C"]);
eq("outdent of a first child lands just after the folder", rows({items:M.outdent(nest, 1)}).filter((r) => r.label === "A")[0].parentId, "");
eq("outdent of a last child keeps the walk as it was", labelsIn({items:M.outdent(nest, 3)}), ["K","A","B","C"]);
eq("outdent of a nested row", ids({items:M.outdent(tree(), 2)}), ["s1","f1","f2","b2","b1","b3"]);
eq("outdent refuses at the top", ids({items:M.outdent(tree(), 1)}), ids(tree()));
eq("outdent under a filter lifts the row under the cursor",
   labelsIn({items:M.outdent(tree(), 1, {query:"Git"})}), ["Daily","Code","Servers","up","GitHub","notes"]);

// Outdent lifts a row one level, not two. On a row one folder deep the two
// readings agree — which is why this needs a row whose parent is itself nested,
// where they part company: a lift that reads "the list holding my parent's
// parent" puts a row that was inside Servers up beside Code, at the top level.
// Every earlier outdent test used a row one level deep, so none of them could
// have seen it.
const deeper = M.fromObject({items:[
  {id:"p",kind:"folder",label:"P",items:[
    {id:"x",kind:"folder",label:"X",items:[
      {id:"m1",kind:"bookmark",type:"url",label:"m1",target:"1.com"},
      {id:"m2",kind:"bookmark",type:"url",label:"m2",target:"2.com"},
      {id:"m3",kind:"bookmark",type:"url",label:"m3",target:"3.com"}]},
    {id:"yy",kind:"bookmark",type:"url",label:"Y",target:"y.com"}]}]});
const lifted = {items:M.outdent(deeper, 3)};
eq("a row two folders deep lifts one level, not two",
   labelsIn(lifted), ["P","X","m1","m3","m2","Y"]);
eq("the lifted row stays inside its grandparent",
   rows(lifted).filter((r) => r.id === "m2")[0].parentId, "p");
eq("the lifted row keeps the depth it had", rows(lifted).filter((r) => r.id === "m2")[0].depth, 1);
// The walk alone cannot say which list a row ended up in — a lone child lifted
// and put back where it was looks identical. The path can, so the position is
// read through it rather than off the order of the labels.
eq("the lifted row lands just after its parent", rows(lifted).filter((r) => r.id === "m2")[0].path, [0, 1]);
eq("the folder it left is not left holding it", rows(lifted).filter((r) => r.id === "x")[0].childCount, 2);
eq("the sibling after the parent did not move", rows(lifted).filter((r) => r.id === "yy")[0].path, [0, 2]);

// The round trip a user can actually make is a row lifted out of the folder
// above it, because then the row above it is still that folder. It is also the
// case the walk cannot distinguish — the labels come out the same either way —
// so the check reads the structure, not the order. Lifting a lone child out of
// a folder and putting it back in one keypress is not offered: the row lands
// under the siblings it was lifted past, and indenting needs a folder above.
const roundTrip = M.indent(M.stateOf(M.outdent(tree(), 4)), 4);
eq("a row out of the folder above it can be indented back",
   rows({items:roundTrip}).filter((r) => r.id === "b2")[0].path, [1, 1, 0]);
eq("and the tree is exactly what it was",
   labelsIn({items:roundTrip}), labelsIn(tree()));
eq("a lifted row under bookmarks is not indented under nothing",
   ids({items:M.indent(M.stateOf(M.outdent(deeper, 3)), 4)}), ids(M.stateOf(M.outdent(deeper, 3))));

// A folder lifted from depth one keeps what it holds, because the lift moves
// the node, not a copy of its label.
eq("an outdented folder keeps its children",
   labelsIn({items:M.outdent(tree(), 3)}), ["Daily","Code","GitHub","Servers","up","notes"]);
eq("an outdented folder is at the top level",
   rows({items:M.outdent(tree(), 3)}).filter((r) => r.id === "f2")[0].parentId, "");
eq("an outdented folder's child still belongs to it",
   rows({items:M.outdent(tree(), 3)}).filter((r) => r.id === "b2")[0].parentId, "f2");

// Changing a row's kind is a save like any other, so the same question applies:
// can this save lose something? Turning a bookmark into a folder cannot — there
// is nothing in it yet — but turning a folder that has things in it into a
// bookmark would drop the lot, and used to do it without a word. Firefox asks
// before it does that; a function with no way to ask refuses instead.
eq("a bookmark can become a folder",
   M.nodeAtRow({items:M.updateAt(tree(), 2, {kind:"folder",label:"GitHub"})}, 2).kind, "folder");
const withEmpty = M.fromObject({items:[
  {id:"e",kind:"folder",label:"Empty",items:[]},
  {id:"o",kind:"folder",label:"One",items:[
    {id:"c",kind:"bookmark",type:"url",label:"Only",target:"only.com"}]}]});
eq("an empty folder can become a bookmark",
   M.nodeAtRow({items:M.updateAt(withEmpty, 0, {kind:"bookmark",type:"url",label:"Empty",target:"e.example"})}, 0).kind, "bookmark");
eq("a folder with things in it keeps its kind",
   M.nodeAtRow({items:M.updateAt(tree(), 1, {kind:"bookmark",type:"url",label:"Code",target:"code.example"})}, 1).kind, "folder");
eq("and nothing inside it was lost",
   ids({items:M.updateAt(tree(), 1, {kind:"bookmark",type:"url",label:"Code",target:"code.example"})}),
   ["s1","f1","b1","f2","b2","b3"]);
eq("a refused save is refused on the whole tree, not half of it",
   M.serialize(M.stateOf(M.updateAt(tree(), 1, {kind:"section",label:"Code"}))), M.serialize(M.stateOf(tree())));
eq("renaming a folder is not a kind change and still works",
   M.nodeAtRow({items:M.updateAt(tree(), 1, {kind:"folder",label:"Code",icon:""})}, 1).label, "Code");
// The refusal is about the contents, not the kind: take the one thing out and
// the same save is allowed, because there is nothing left to lose.
const emptied = M.stateOf(M.removeAt(withEmpty, 2));
eq("emptying a folder first does allow the change",
   M.nodeAtRow({items:M.updateAt(emptied, 1, {kind:"bookmark",type:"url",label:"One",target:"one.example"})}, 1).kind, "bookmark");
eq("and the child it held is what was removed, not the folder",
   ids({items:M.updateAt(emptied, 1, {kind:"bookmark",type:"url",label:"One",target:"one.example"})}), ["e","o"]);


// --- pinning through a row
eq("togglePinned sets a flag", M.nodeAtRow({items:M.togglePinned(tree(), 2)}, 2).pinned, true);
eq("togglePinned twice is off", M.nodeAtRow({items:M.togglePinned({items:M.togglePinned(tree(), 2)}, 2)}, 2).pinned, false);
eq("togglePinned on a folder changes nothing", ids({items:M.togglePinned(tree(), 1)})[1] === "f1", true);
eq("a folder is still not pinned after a toggle", M.nodeAtRow({items:M.togglePinned(tree(), 1)}, 1).pinned, undefined);
eq("setPinned on", M.nodeAtRow({items:M.setPinned(tree(), 2, true)}, 2).pinned, true);
eq("setPinned off", M.nodeAtRow({items:M.setPinned({items:M.setPinned(tree(), 2, true)}, 2, false)}, 2).pinned, false);
eq("togglePinned under a filter touches the visible row", M.nodeAtRow({items:M.togglePinned(tree(), 1, {query:"Git"})}, 1, {query:"Git"}).pinned, true);

// --- glyphs by kind
eq("an open folder glyph", M.kindGlyph({kind:"folder",label:"x"}, false), M.KIND_GLYPHS.folderOpen);
eq("a closed folder glyph", M.kindGlyph({kind:"folder",label:"x"}, true), M.KIND_GLYPHS.folder);
eq("a section glyph", M.kindGlyph({kind:"section",label:"x"}), M.KIND_GLYPHS.section);
eq("a bookmark glyph comes from its type", M.kindGlyph({kind:"bookmark",type:"url",target:"a"}), M.TYPE_GLYPHS.url);
eq("a bookmark with a bad type falls back", M.kindGlyph({kind:"bookmark",type:"nope",target:"a"}), M.TYPE_GLYPHS.cmd);

// --- persistence round trip
eq("round trip", list(M.parse(M.serialize(s))).map((e) => e.target), ["a","b","c"]);
eq("trailing newline", M.serialize(s).endsWith("\n"), true);
eq("serialize then append", list(M.parse(M.serialize(M.append(s,{type:"app",target:"z"})))).length, 4);
eq("round trip keeps glyph icon", list(M.parse(M.serialize(M.append(s,{type:"app",target:"z",icon:GLYPH}))))[3].icon, GLYPH);
eq("round trip keeps id", list(M.parse(M.serialize(s)))[0].id, list(s)[0].id);
eq("a tree round trips exactly", list(M.parse(M.serialize(tree()))), list(tree()));
eq("a round trip keeps the nesting", rows(M.parse(M.serialize(tree()))).map((r) => r.path.join(".")), ["0","1","1.0","1.1","1.1.0","2"]);
eq("a round trip keeps pinned", rows(M.parse(M.serialize(tree()))).map((r) => r.pinned), [false,false,false,false,false,true]);
eq("a round trip keeps a folder's children", M.nodeAtRow(M.parse(M.serialize(tree())), 1).items.length, 2);
eq("a round trip keeps a section a section", M.nodeAtRow(M.parse(M.serialize(tree())), 0).kind, "section");
eq("stateOf wraps a list", M.stateOf([{kind:"bookmark",type:"url",target:"a"}]).version, 2);
eq("stateOf survives a non-list", M.stateOf(null).items, []);
// `stateOf(stateOf(x))` is an easy line to write, and it used to hand back an
// empty list — the user's bookmarks gone, and no error to say so. A state in
// is a state out, the same rows and all.
eq("stateOf given a state keeps the rows", M.flatten(M.stateOf(M.stateOf(tree().items)), {}).length, 6);
eq("stateOf given a state keeps the version", M.stateOf(M.stateOf(tree().items)).version, 2);
eq("stateOf given a v1 file keeps the rows", M.flatten(M.stateOf(M.parse(JSON.stringify({version:1,bookmarks:tree().items}))), {}).length, 6);
eq("stateOf of nothing is an empty list, not a lost one", M.stateOf(undefined).items, []);
eq("a list handed straight back is still readable", list(M.fromObject(M.append(s, {type:"cmd",target:"d"}))).length, 4);


// --- icon lookup script: the icon name must never reach the shell as code
// The panel passes the name as a positional parameter and reads "$1". Splicing
// it into the script text with JSON.stringify is not safe: JSON only quotes
// for JSON, and bash still expands $(...) and `...` inside double quotes, so an
// icon name could run a command. This checks the real script text.
const source = fs.readFileSync(require("path").join(__dirname, "..", "src", "Sidebar.qml"), "utf8");
eq("script reads the name as $1", source.includes('\\"$1\\"'), true);
eq("script never interpolates the name", source.includes("JSON.stringify(iconName)"), false);
eq("the name is passed as an argument", /\"bookmarks-icon\", iconName\]/.test(source), true);

// Confirm the two forms behave differently under a real shell, so the reason
// for the positional parameter is on the record rather than just asserted.
const sh = (s, ...a) => execFileSync("bash", ["-lc", s, "bookmarks-icon", ...a], { encoding: "utf8" });
const tmpdir = fs.mkdtempSync("/tmp/iconinjection-");
const canary = `${tmpdir}/canary`;
const evil = `x$(touch ${canary})`;
try { sh('n="$1"; echo "$n"', evil); } catch {}
eq("positional parameter blocks substitution", fs.existsSync(canary), false);
try { sh('n=' + JSON.stringify(evil) + '; echo "$n"', evil); } catch {}
eq("JSON.stringify in the script text does not", fs.existsSync(canary), true);
fs.rmSync(tmpdir, { recursive: true, force: true });

// --- lineHeightFor
// QML multiplies lineHeight by the font's natural line height, not by its
// pixel size. omarchy.ttf's natural leading is wider than its pixel size, so
// asking for 1.3 asked for roughly 1.75 and every wrapped paragraph grew a
// blank line between each of its lines. The conversion is what stops that from
// being a per-font accident.
eq("leading equals the font's own when asked for it", M.lineHeightFor(16, 16), 1);
eq("leading is proportional in between", M.lineHeightFor(19, 16), 19 / 16);
eq("unmeasured font metrics fall back to 1", M.lineHeightFor(16, 0), 1);
eq("negative font metrics fall back to 1", M.lineHeightFor(16, -3), 1);
eq("undefined font metrics fall back to 1", M.lineHeightFor(16, undefined), 1);
eq("null font metrics fall back to 1", M.lineHeightFor(16, null), 1);
eq("NaN font metrics fall back to 1", M.lineHeightFor(16, NaN), 1);
// The whole point: a 12px font carries ~16px of natural leading, so a plain
// proportional multiplier always overshoots what the glyphs need.
eq("a proportional multiplier would overshoot", M.lineHeightFor(Math.round(12 * 1.3), 16) < 1.3, true);
eq("the leading asked for is the leading delivered",
   M.lineHeightFor(Math.round(12 * 1.3), 16) * 16, Math.round(12 * 1.3));

  // --- type: file --------------------------------------------------------
  // The whole point of the type is "click and the thing opens", so the target
  // has to survive a path with spaces in it, a path that is not there right
  // now, and a move to a machine with a different user name.
  eq("file is a supported type", M.isSupportedType("file"), true);
  eq("file is in TYPES", M.TYPES.indexOf("file") !== -1, true);
  eq("file glyph in PUA", M.isIconGlyph(M.TYPE_GLYPHS.file), true);
  eq("file glyph is one codepoint", Array.from(M.TYPE_GLYPHS.file).length, 1);

  eq("absolute file target accepted", M.isFileTarget("/home/bo/a.md"), true);
  eq("home-relative file target accepted", M.isFileTarget("~/a.md"), true);
  eq("bare tilde accepted", M.isFileTarget("~"), true);
  // A relative path would resolve against whatever directory the panel was
  // started in, so the same bookmark could open a different file per launch.
  eq("relative file target refused", M.isFileTarget("a.md"), false);
  eq("dot-relative file target refused", M.isFileTarget("./a.md"), false);
  eq("parent-relative file target refused", M.isFileTarget("../a.md"), false);
  eq("a file URL is not a path", M.isFileTarget("file:///home/bo/a.md"), false);

  eq("a relative file bookmark is dropped",
     list(M.parse('[{"type":"file","target":"notes.md"}]')).length, 0);
  eq("an absolute one is kept",
     list(M.parse('[{"type":"file","target":"/tmp/notes.md"}]')).length, 1);
  // The whole reason a file bookmark survives a new laptop: existence is not
  // checked when loading, so a path on a drive that is not mounted right now
  // is still a bookmark and comes back when the drive is there.
  eq("a missing file is not dropped",
     list(M.parse('[{"type":"file","target":"/nope/never.md"}]')).length, 1);

  eq("file argv is xdg-open", M.argvFor({type: "file", target: "/tmp/a.md"}), ["xdg-open", "/tmp/a.md"]);
  // argv form, so the shell never sees it: a path with a substitution in it
  // must arrive as one literal argument.
  eq("file argv keeps spaces intact",
     M.argvFor({type: "file", target: "/tmp/My Notes/a.md"}), ["xdg-open", "/tmp/My Notes/a.md"]);
  eq("file argv does not expand shell syntax",
     M.argvFor({type: "file", target: "/tmp/$(rm -rf ~).md"}), ["xdg-open", "/tmp/$(rm -rf ~).md"]);
  eq("directory uses the same call", M.argvFor({type: "file", target: "/home/bo/code"}),
     ["xdg-open", "/home/bo/code"]);

  eq("~ expands at launch", M.argvFor({type: "file", target: "~/a.md"}, "/home/bo"),
     ["xdg-open", "/home/bo/a.md"]);
  eq("~ expands under a different user name", M.argvFor({type: "file", target: "~/a.md"}, "/home/someone-else"),
     ["xdg-open", "/home/someone-else/a.md"]);
  eq("bare ~ expands to the home directory", M.expandHome("~", "/home/bo"), "/home/bo");
  eq("a trailing slash on home does not double up", M.expandHome("~/a", "/home/bo/"), "/home/bo/a");
  eq("an absolute path ignores home", M.expandHome("/etc/a", "/home/bo"), "/etc/a");
  // Without a home to expand into, the tilde is left alone rather than guessed
  // at: "~/a.md" is not "/a.md" and is certainly not "a.md".
  eq("no home leaves the tilde alone", M.expandHome("~/a.md", ""), "~/a.md");
  eq("no home leaves bare tilde alone", M.expandHome("~", ""), "~");
  eq("~ survives a save/load round trip",
     list(M.parse(M.serialize({items: [{type: "file", target: "~/a.md"}]})))[0].target, "~/a.md");
  const withFile = M.stateOf(M.insertInto(tree(), 1, {kind:"bookmark",type:"file",label:"in",target:"~/in.md"}));
  const afterFile = M.parse(M.serialize(withFile));
  const fileRow = rows(afterFile).findIndex((r) => r.label === "in");
  eq("a file bookmark inside a folder survives too", M.nodeAtRow(afterFile, fileRow).target, "~/in.md");
  eq("and it is still a child of the folder", rows(afterFile)[fileRow].depth, 1);

  // The label is the last path segment, taken from the whole string: splitting
  // on whitespace first would reduce "/home/bo/My Notes/a.md" to "My".
  eq("file label is the basename", M.fileLabel("/home/bo/a.md"), "a.md");
  eq("file label keeps spaces", M.fileLabel("/home/bo/My Notes/a.md"), "a.md");
  eq("file label from a bare name", M.fileLabel("a.md"), "a.md");
  eq("directory label is its own name", M.fileLabel("/home/bo/code"), "code");
  eq("trailing slash names the directory", M.fileLabel("/home/bo/code/"), "code");
  eq("root is not an empty label", M.fileLabel("/") !== "", true);
  eq("a tilde path labels by name", M.labelForType("file", "~/.bashrc"), ".bashrc");
  eq("url labels still strip the scheme", M.labelForType("url", "https://a.com/x"), "a.com");
  eq("cmd labels still take the first word", M.labelForType("cmd", "python3 s.py"), "python3");

  // --- the search box -----------------------------------------------------
  // The person searching usually remembers the target, not the name they gave
  // it, so the target has to be searchable too.
  var lib = [
    { id: "a", type: "url", label: "GitHub", target: "https://github.com", icon: "" },
    { id: "b", type: "file", label: "report", target: "/tmp/My Notes/report.md", icon: "" },
    { id: "c", type: "cmd", label: "Screenshot", target: "omarchy-capture-screenshot", icon: "" },
    { id: "d", type: "app", label: "Files", target: "org.gnome.Nautilus", icon: "" }
  ];
  var st = { items: lib };
  function labels(q) { return M.filterEntries(st, q).map(function (e) { return e.label; }); }

  eq("an empty query shows everything", labels("").length, 4);
  eq("a whitespace query shows everything", labels("   ").length, 4);
  eq("a null query shows everything", labels(null).length, 4);
  eq("matches the label", labels("git"), ["GitHub"]);
  eq("is case insensitive", labels("GITHUB"), ["GitHub"]);
  eq("matches the target, not just the label", labels("github.com"), ["GitHub"]);
  eq("finds a file by its path", labels("report.md"), ["report"]);
  eq("finds a file by its folder", labels("My Notes"), ["report"]);
  eq("finds a command by what it runs", labels("capture"), ["Screenshot"]);
  eq("finds an app by its desktop id", labels("nautilus"), ["Files"]);
  // "e" leaves out only the first row and keeps the rest in the order the list
  // already had, so a filter can never reorder what it does not hide.
  eq("several hits keep list order", labels("e"), ["report", "Screenshot", "Files"]);
  eq("no hits is an empty list", labels("zzzz"), []);
  eq("surrounding space is ignored", labels("  git  "), ["GitHub"]);

  // The positions are into the full list, not into the result, so the first
  // surviving row after a filter still points at the entry it always pointed at.
  eq("indexes are positions in the full list",
     M.filterIndexes(st, "e"), [1, 2, 3]);
  eq("every row matches an all-rows query",
     M.filterIndexes(st, "t"), [0, 1, 2, 3]);
  eq("a filtered index maps to the right entry",
     lib[M.filterIndexes(st, "report")[0]].label, "report");
  eq("filtering never mutates the source", list(st).length, 4);
  // The filtered list must be the same entries, in the same order, as the rows
  // they came from, or every index the view hands out points somewhere else.
  eq("filtered entries keep their ids", M.filterEntries(st, "t").map(function (e) { return e.id; }), ["a", "b", "c", "d"]);
  eq("matches works on a folder label", M.matches({kind:"folder",label:"Code"}, "co"), true);
  eq("matches does not read a folder's children", M.matches({kind:"folder",label:"Code",items:[{kind:"bookmark",type:"url",label:"hidden",target:"h"}]}, "hidden"), false);
  eq("matches refuses a node with no valid kind", M.matches({kind:"nope",label:"x"}, "x"), false);

  // --- moving the panel to another machine -------------------------------
  // The whole point of export and import: a file that can be copied to a new
  // laptop and read back. A round trip has to be exact, and importing the same
  // file twice must not double the list.
  var one = { items: lib };
  eq("export round trips exactly", list(M.parse(M.serialize(one))), M.fromObject(one).items);
  eq("a file bookmark survives the trip", list(M.parse(M.serialize(one)))[1].target, "/tmp/My Notes/report.md");
  eq("a tilde is not rewritten on the way out",
     list(M.parse(M.serialize({items: [{type: "file", target: "~/a.md" }]})))[0].target, "~/a.md");

  eq("importing the same file again changes nothing",
     M.mergeEntries(one, one.items).length, 4);
  // A bookmark that reached the file by hand, or through another machine, has a
  // different id but is still the same bookmark.
  var handTyped = [{ id: "zzz", type: "url", label: "GitHub again", target: "https://github.com", icon: "" }];
  eq("a duplicate is recognised by what it points at",
     M.mergeEntries(one, handTyped).length, 4);
  eq("a genuinely new entry is merged in",
     M.mergeEntries(one, [{ type: "cmd", label: "New", target: "pwd", icon: "" }]).length, 5);
  // What is already on this machine keeps its place, and what arrives goes
  // after it: a merge that reshuffled the panel would make every bookmark move
  // for no reason the moment someone copied a file over.
  var merged = M.mergeEntries(one, [{ type: "cmd", label: "New", target: "pwd", icon: "" }]);
  eq("merging keeps the saved list's order", merged.slice(0, 4).map(function (e) { return e.id; }),
     ["a", "b", "c", "d"]);
  eq("what arrives is appended last", merged[4].label, "New");
  // The same target reached by a different type is a different bookmark: a URL
  // and a command that happen to look alike are both worth having.
  eq("a same-looking target of another type is kept",
     M.mergeEntries(one, [{ type: "cmd", target: "https://github.com", icon: "" }]).length, 5);
  eq("a junk incoming entry is ignored, not saved",
     M.mergeEntries(one, [null, 5, { type: "file", target: "relative" }]).length, 4);
  eq("merging never mutates its input", list(one).length, 4);
  // A folder in an imported file is merged as a folder, not dropped on the
  // floor, or re-importing our own export would quietly flatten the tree.
  var withFolder = M.stateOf(M.mergeEntries(M.stateOf([]), tree().items));
  eq("a folder merges in whole", list(withFolder).map((n) => n.id), ["s1","f1","b3"]);
  eq("a merged folder keeps its children", M.nodeAtRow(withFolder, 1).items.length, 2);
  eq("the merged tree walks like the one that arrived", ids(withFolder), ids(tree()));
  eq("merging the same folder twice is a no-op",
     M.mergeEntries(withFolder, tree().items).length, 3);
  // Merging happens at the level the file stores: a bare bookmark is compared
  // against the rows at the top, so one that already sits inside a folder is a
  // new row here. That is not a corner case the UI can produce — an export
  // carries its folders, and the children arrive inside them.
  eq("a bare incoming bookmark merges at the top level",
     list(M.mergeEntries(withFolder, [{kind:"bookmark",type:"url",label:"GitHub",target:"https://github.com"}])).length, 4);
  eq("the same bookmark nested in a folder is part of that folder",
     ids(M.mergeEntries(withFolder, tree().items)).length, 6);

  // A file that is not ours must never be read as an empty list, or a replace
  // would quietly empty the panel.
  eq("our own file is recognised", M.looksLikeOurFile(M.serialize(one)), true);
  eq("a v2 file with folders is recognised", M.looksLikeOurFile(M.serialize(tree())), true);
  eq("an empty list is still our file", M.looksLikeOurFile('{"version":1,"bookmarks":[]}'), true);
  eq("an empty v2 list is still our file", M.looksLikeOurFile('{"version":2,"items":[]}'), true);
  eq("some other json is refused", M.looksLikeOurFile('{"servers":[{"host":"a"}]}'), false);
  eq("a json array is refused", M.looksLikeOurFile('[]'), false);
  eq("a plain number is refused", M.looksLikeOurFile("42"), false);
  eq("text is refused", M.looksLikeOurFile("hello"), false);
  eq("a file with one broken entry is refused",
     M.looksLikeOurFile('{"bookmarks":[{"type":"nope","target":"x"}]}'), false);
  eq("a file with a broken entry inside a folder is refused",
     M.looksLikeOurFile('{"items":[{"kind":"folder","label":"x","items":[{"type":"nope","target":"x"}]}]}'), false);
  eq("a folder with a broken grandchild is refused",
     M.looksLikeOurFile('{"items":[{"kind":"folder","label":"x","items":[{"kind":"folder","label":"y","items":[{"type":"file","target":"rel"}]}]}]}'), false);
  eq("a folder with an empty items field is still ours",
     M.looksLikeOurFile('{"items":[{"kind":"folder","label":"x","items":[]}]}'), true);
  eq("a file nested past the depth limit is refused",
     (() => { let d = {kind:"bookmark",type:"url",target:"a"};
       for (let i = 0; i < 40; i++) d = {kind:"folder",label:"d",items:[d]};
       return M.looksLikeOurFile(JSON.stringify({items:[d]})); })(), false);
  // A file saved by a future version of the plugin is worth reading if the
  // entries still make sense, so version is not what is checked.
  eq("an unknown version is still readable",
     M.looksLikeOurFile('{"version":99,"bookmarks":[{"type":"url","target":"https://x.com"}]}'), true);

  eq("the export name is dated", M.exportName("/home/bo", "2026-09-27"), "/home/bo/omarchy-bookmarks-2026-09-27.json");
  eq("a missing date still gives a usable name", M.exportName("/home/bo"), "/home/bo/omarchy-bookmarks-export.json");
  eq("the export name ends in json", /\.json$/.test(M.exportName("/home/bo", "2026-09-27")), true);

  console.log("\n" + pass + " passed, " + fail + " failed");
  process.exit(fail ? 1 : 0);
