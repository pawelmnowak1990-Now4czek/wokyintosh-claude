#!/usr/bin/env node
// Prints the image prompt for one idea, using the same builder as the Kronika page
// (kronika/kronika-memow.html), so prompts never drift between the page and scripts.
//
//   node tools/prompt.js --list
//   node tools/prompt.js 1066-harold-wilhelm            # PL text (default)
//   node tools/prompt.js 1066-harold-wilhelm en         # EN text
//   node tools/prompt.js 1066-harold-wilhelm none       # no text, lettering added later
//   node tools/prompt.js 1066-harold-wilhelm pl --caption

const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const ideasDir = path.join(root, "data", "ideas");
const page = fs.readFileSync(path.join(root, "kronika", "kronika-memow.html"), "utf8");

function loadBuilder() {
  const start = page.indexOf("  function buildPrompt(");
  const end = page.indexOf("  function captionFor(");
  if (start < 0 || end < 0) throw new Error("buildPrompt not found in kronika/kronika-memow.html");
  return new Function(page.slice(start, end) + "; return buildPrompt;")();
}

function loadIdeas() {
  return fs.readdirSync(ideasDir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => ({ id: f.slice(0, -5), ...JSON.parse(fs.readFileSync(path.join(ideasDir, f), "utf8")) }))
    .sort((a, b) => (a.year ?? 99999) - (b.year ?? 99999));
}

const args = process.argv.slice(2);
const ideas = loadIdeas();

if (!args.length || args[0] === "--list") {
  for (const i of ideas) console.log(`${i.id.padEnd(26)} ${String(i.yearLabel).padEnd(14)} [${i.status}] ${i.title}`);
  process.exit(0);
}

const [id, lang = "pl"] = args;
if (!["pl", "en", "none"].includes(lang)) {
  console.error(`Unknown language "${lang}". Use pl, en or none.`);
  process.exit(1);
}
const idea = ideas.find((i) => i.id === id);
if (!idea) {
  console.error(`No idea "${id}". Run with --list to see ids.`);
  process.exit(1);
}

console.log(loadBuilder()(idea, lang));
if (args.includes("--caption")) {
  console.log("\n---\n" + (lang === "en" && idea.captionEn ? idea.captionEn : idea.caption));
}
