const fs = require("fs");
const src = fs.readFileSync(require("path").join(__dirname, "..", "src", "BookmarkModel.js"), "utf8");
  const M = new Function(src + "\nreturn {parse,serialize,append,updateAt,removeAt,moveBy,argvFor,iconKind,labelFor,makeId,isIconGlyph,isDesktopId,isSeparatorGlyph,labelForType,TYPE_GLYPHS,typeGlyph,lineHeightFor,isFileTarget,expandHome,fileLabel,TYPES,isSupportedType,matches,filterIndexes,filterEntries,mergeEntries,looksLikeOurFile,exportName};")();

const GLYPH = String.fromCodePoint(0x0F488);   // Browser, from stock omarchy menu
const APPGLYPH = String.fromCodePoint(0xF003B); // Apps
let pass = 0, fail = 0;
const eq = (name, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) pass++; else { fail++; console.log("FAIL", name, "\n  got ", g, "\n  want", w); }
};

// --- glyph constants are real single codepoints in the PUA
eq("type glyph single char", Array.from(M.TYPE_GLYPHS.url).length, 1);
eq("type glyph in PUA", M.isIconGlyph(M.TYPE_GLYPHS.url), true);
eq("type glyph app in PUA", M.isIconGlyph(M.TYPE_GLYPHS.app), true);
eq("type glyph cmd in PUA", M.isIconGlyph(M.TYPE_GLYPHS.cmd), true);
eq("glyph browser", M.TYPE_GLYPHS.url, GLYPH);
eq("glyph apps", M.TYPE_GLYPHS.app, APPGLYPH);
eq("typeGlyph fallback", M.typeGlyph("nope"), M.TYPE_GLYPHS.cmd);

// --- parsing / normalisation
eq("parse empty", M.parse(""), {version:1,bookmarks:[]});
eq("parse garbage", M.parse("{oops"), {version:1,bookmarks:[]});
eq("parse null", M.parse(null), {version:1,bookmarks:[]});
eq("parse not json array", M.parse("5"), {version:1,bookmarks:[]});
eq("bare array ok", M.parse('[{"type":"url","target":"https://a.com"}]').bookmarks.length, 1);
eq("drops bad type", M.parse('[{"type":"nope","target":"x"},{"type":"app","target":"ok"}]').bookmarks.length, 1);
eq("drops empty target", M.parse('[{"type":"app","target":"  "}]').bookmarks.length, 0);
eq("drops non-object", M.parse('[null,"x",5,{"type":"cmd","target":"ls"}]').bookmarks.length, 1);
eq("type lowercased", M.parse('[{"type":"URL","target":"https://a.com"}]').bookmarks[0].type, "url");
eq("target trimmed", M.parse('[{"type":"app","target":"  firefox  "}]').bookmarks[0].target, "firefox");

// --- labels
eq("url label", M.labelForType("url","https://github.com/qwpemore"), "github.com");
eq("url label no path", M.labelForType("url","https://example.com"), "example.com");
eq("url label cuts path", M.labelForType("url","https://a.co/x/y?q=1"), "a.co");
eq("url label query only", M.labelForType("url","https://a.co?q=1"), "a.co?q=1");
eq("app strips path", M.labelForType("app","/usr/bin/firefox"), "firefox");
eq("cmd first word", M.labelForType("cmd","omarchy-capture-screenshot --full"), "omarchy-capture-screenshot");
eq("explicit label wins", M.parse('[{"type":"url","target":"https://a.com","label":"Mine"}]').bookmarks[0].label, "Mine");

// --- ids
const a = M.parse('[{"type":"app","target":"a"}]').bookmarks[0];
const b = M.parse('[{"type":"app","target":"b"}]').bookmarks[0];
eq("id assigned", !!a.id, true);
eq("ids unique", a.id !== b.id, true);
eq("dup id repaired", M.parse('[{"id":"x","type":"app","target":"a"},{"id":"x","type":"app","target":"b"}]').bookmarks[1].id !== "x", true);
eq("update keeps id", M.updateAt({version:1,bookmarks:[a,b]}, 0, {type:"cmd",target:"ls"})[0].id, a.id);

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
eq("glyph promoted from target", M.parse('[{"type":"app","target":' + JSON.stringify(APPGLYPH) + '}]').bookmarks[0].icon, APPGLYPH);
eq("bad icon dropped", M.parse('[{"type":"app","target":"a","icon":"a/b"}]').bookmarks[0].icon, "");

// --- argv construction (no shell for url/app)
eq("url argv", M.argvFor({type:"url",target:"https://a.com"}), ["omarchy-launch-webapp","https://a.com"]);
eq("app argv bare command", M.argvFor({type:"app",target:"firefox"}), ["uwsm-app","--","firefox"]);
eq("app argv desktop", M.argvFor({type:"app",target:"org.gnome.Nautilus"}), ["gtk-launch","org.gnome.Nautilus"]);
eq("cmd argv", M.argvFor({type:"cmd",target:"ls | wc -l"}), ["bash","-c","ls | wc -l"]);
eq("argv rejects bad type", M.argvFor({type:"bad",target:"x"}), []);
eq("argv rejects empty", M.argvFor({type:"url",target:""}), []);
eq("injection stays one arg", M.argvFor({type:"url",target:"x; rm -rf /"}).length, 2);
eq("injection literal", M.argvFor({type:"url",target:"x; rm -rf /"})[1], "x; rm -rf /");

// --- every launcher the model can emit must exist on this machine
// The suite above happily asserted an argv whose first element was a command
// that was never installed, so the shape of the argv is checked against the
// real PATH here. Only the program is checked: the target is user data.
const { execFileSync } = require("child_process");
const which = (p) => { try { execFileSync("which", [p], { stdio: ["ignore", "pipe", "ignore"] }); return true; } catch { return false; } };
const emitted = new Set();
for (const t of ["url", "app", "cmd"])
  for (const target of ["https://a.com", "org.gnome.Nautilus", "firefox", "ls"]) {
    const argv = M.argvFor({ type: t, target });
    // argv[0] is always the program; everything after it is user data.
    if (argv.length > 0) emitted.add(argv[0]);
  }

for (const prog of [...emitted].sort())
  eq(`${prog} exists on PATH`, which(prog), true);

// --- mutations
let s = {version:1,bookmarks:M.parse('[{"type":"app","target":"a"},{"type":"app","target":"b"},{"type":"app","target":"c"}]').bookmarks};
eq("append", M.append(s,{type:"cmd",target:"d"}).length, 4);
eq("append rejects junk", M.append(s,{type:"cmd",target:""}).length, 3);
eq("updateAt oob", M.updateAt(s,9,{type:"app",target:"z"}).length, 3);
eq("updateAt rejects junk", M.updateAt(s,0,{type:"app",target:""}).length, 3);
eq("removeAt", M.removeAt(s,0).map(e=>e.target), ["b","c"]);
eq("removeAt oob", M.removeAt(s,5).length, 3);
eq("moveBy down", M.moveBy(s,0,1).map(e=>e.target), ["b","a","c"]);
eq("moveBy up", M.moveBy(s,2,-1).map(e=>e.target), ["a","c","b"]);
eq("moveBy clamps low", M.moveBy(s,0,-1).map(e=>e.target), ["a","b","c"]);
eq("moveBy clamps high", M.moveBy(s,2,1).map(e=>e.target), ["a","b","c"]);
eq("moveBy oob", M.moveBy(s,9,1).length, 3);

// --- persistence round trip
eq("round trip", M.parse(M.serialize(s)).bookmarks.map(e=>e.target), ["a","b","c"]);
eq("trailing newline", M.serialize(s).endsWith("\n"), true);
eq("serialize then append", M.parse(M.serialize(M.append(s,{type:"app",target:"z"}))).bookmarks.length, 4);
eq("round trip keeps glyph icon", M.parse(M.serialize(M.append(s,{type:"app",target:"z",icon:GLYPH}))).bookmarks[3].icon, GLYPH);
eq("round trip keeps id", M.parse(M.serialize(s)).bookmarks[0].id, s.bookmarks[0].id);


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
     M.parse('[{"type":"file","target":"notes.md"}]').bookmarks.length, 0);
  eq("an absolute one is kept",
     M.parse('[{"type":"file","target":"/tmp/notes.md"}]').bookmarks.length, 1);
  // The whole reason a file bookmark survives a new laptop: existence is not
  // checked when loading, so a path on a drive that is not mounted right now
  // is still a bookmark and comes back when the drive is there.
  eq("a missing file is not dropped",
     M.parse('[{"type":"file","target":"/nope/never.md"}]').bookmarks.length, 1);

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
     M.parse(M.serialize({version: 1, bookmarks: [{type: "file", target: "~/a.md"}]}))
       .bookmarks[0].target, "~/a.md");

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
  var st = { version: 1, bookmarks: lib };
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
  eq("filtering never mutates the source", st.bookmarks.length, 4);
  // The filtered list must be the same entries, in the same order, as the rows
  // they came from, or every index the view hands out points somewhere else.
  eq("filtered entries keep their ids", M.filterEntries(st, "t").map(function (e) { return e.id; }), ["a", "b", "c", "d"]);

  // --- moving the panel to another machine -------------------------------
  // The whole point of export and import: a file that can be copied to a new
  // laptop and read back. A round trip has to be exact, and importing the same
  // file twice must not double the list.
  var one = { version: 1, bookmarks: lib };
  eq("export round trips exactly", M.parse(M.serialize(one)).bookmarks, one.bookmarks);
  eq("a file bookmark survives the trip", M.parse(M.serialize(one)).bookmarks[1].target, "/tmp/My Notes/report.md");
  eq("a tilde is not rewritten on the way out",
     M.parse(M.serialize({ version: 1, bookmarks: [{ type: "file", target: "~/a.md" }] })).bookmarks[0].target, "~/a.md");

  eq("importing the same file again changes nothing",
     M.mergeEntries(one, one.bookmarks).length, 4);
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
  eq("merging never mutates its input", one.bookmarks.length, 4);

  // A file that is not ours must never be read as an empty list, or a replace
  // would quietly empty the panel.
  eq("our own file is recognised", M.looksLikeOurFile(M.serialize(one)), true);
  eq("an empty list is still our file", M.looksLikeOurFile('{"version":1,"bookmarks":[]}'), true);
  eq("some other json is refused", M.looksLikeOurFile('{"servers":[{"host":"a"}]}'), false);
  eq("a json array is refused", M.looksLikeOurFile('[]'), false);
  eq("a plain number is refused", M.looksLikeOurFile("42"), false);
  eq("text is refused", M.looksLikeOurFile("hello"), false);
  eq("a file with one broken entry is refused",
     M.looksLikeOurFile('{"bookmarks":[{"type":"nope","target":"x"}]}'), false);
  // A file saved by a future version of the plugin is worth reading if the
  // entries still make sense, so version is not what is checked.
  eq("an unknown version is still readable",
     M.looksLikeOurFile('{"version":99,"bookmarks":[{"type":"url","target":"https://x.com"}]}'), true);

  eq("the export name is dated", M.exportName("/home/bo", "2026-09-27"), "/home/bo/omarchy-bookmarks-2026-09-27.json");
  eq("a missing date still gives a usable name", M.exportName("/home/bo"), "/home/bo/omarchy-bookmarks-export.json");
  eq("the export name ends in json", /\.json$/.test(M.exportName("/home/bo", "2026-09-27")), true);

  console.log("\n" + pass + " passed, " + fail + " failed");
  process.exit(fail ? 1 : 0);
