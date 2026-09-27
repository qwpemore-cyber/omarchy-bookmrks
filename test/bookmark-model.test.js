const fs = require("fs");
const src = fs.readFileSync(require("path").join(__dirname, "..", "src", "BookmarkModel.js"), "utf8");
const M = new Function(src + "\nreturn {parse,serialize,append,updateAt,removeAt,moveBy,argvFor,iconKind,labelFor,makeId,isIconGlyph,isDesktopId,isSeparatorGlyph,labelForType,TYPE_GLYPHS,typeGlyph};")();

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

console.log("\n" + pass + " passed, " + fail + " failed");
process.exit(fail ? 1 : 0);
