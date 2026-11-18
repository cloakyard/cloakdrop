/** Validate README navigation and local references without network or runtime dependencies. */
import assert from "node:assert/strict";
import { readFile, stat } from "node:fs/promises";
import { resolve, dirname, extname, relative } from "node:path";
const sections = [
  "Overview",
  "Features",
  "Privacy",
  "Getting started",
  "Development",
  "Design and assets",
  "Project structure",
  "Deployment and releases",
  "Contributing",
  "License",
];
const args = process.argv.slice(2);
assert(
  args.length === 0 || (args.length === 2 && args[0] === "--family"),
  "Use --family /path/to/checkouts",
);
const root = args.length ? resolve(args[1]) : resolve(import.meta.dirname, "..");
const files = args.length
  ? ["cloakyard", "cloakpdf", "cloakimg", "cloakresume", "cloakdrop", "cloakroll", "cloaktools"].flatMap(
      (app) => [
        `${app}/README.md`,
        ...(["cloakdrop", "cloakroll", "cloaktools"].includes(app) ? [`${app}/apps/site/README.md`] : []),
      ],
    )
  : ["README.md", "apps/site/README.md"];
function prose(text) {
  return text.replace(/^(`{3,}|~{3,})[^\n]*\n[\s\S]*?^\1\s*$/gm, "");
}
function anchors(text) {
  const result = new Set([...text.matchAll(/\b(?:id|name)=["']([^"']+)["']/g)].map((m) => m[1]));
  const counts = new Map();
  for (const [, heading] of prose(text).matchAll(/^#{1,6} (.+)$/gm)) {
    const slug = heading
      .toLowerCase()
      .replace(/<[^>]*>/g, "")
      .replace(/[^\p{L}\p{N}_\-\s]/gu, "")
      .replace(/ /g, "-");
    const count = counts.get(slug) || 0;
    result.add(count ? `${slug}-${count}` : slug);
    counts.set(slug, count + 1);
  }
  return result;
}
let links = 0;
const errors = [];
for (const file of files) {
  const path = resolve(root, file);
  const text = await readFile(path, "utf8");
  const body = prose(text);
  const headings = [...body.matchAll(/^## (.+)$/gm)].map((m) => m[1]);
  if (JSON.stringify(headings) !== JSON.stringify(sections))
    errors.push(`${file}: incorrect section order`);
  if ([...body.matchAll(/^# /gm)].length !== 1 || !body.startsWith("# "))
    errors.push(`${file}: one leading H1 required`);
  for (const part of text.split(/^## .+$/m).slice(1))
    if (!part.trim()) errors.push(`${file}: empty section`);
  const refs = [
    ...[...body.matchAll(/!?\[[^\]\n]*\]\(([^)]+)\)/g)].map((m) => m[1]),
    ...[...body.matchAll(/\b(?:href|src|srcset)=["']([^"']+)["']/g)].map((m) => m[1]),
  ];
  for (let ref of new Set(refs)) {
    if (/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(ref)) continue;
    ref = ref.replace(/^<|>$/g, "").replace(/\s+["'][\s\S]*$/, "");
    const [pathname, hash] = ref.split("#");
    const target = pathname
      ? resolve(dirname(path), decodeURIComponent(pathname.split("?")[0]))
      : path;
    try {
      const info = await stat(target);
      if (hash && info.isFile() && extname(target).toLowerCase() === ".md") {
        const ids = anchors(target === path ? text : await readFile(target, "utf8"));
        if (!ids.has(decodeURIComponent(hash))) throw new Error(`missing anchor #${hash}`);
      }
      links++;
    } catch (error) {
      errors.push(`${file}: ${ref} (${error.code || error.message})`);
    }
  }
}
if (errors.length) throw new Error(errors.join("\n"));
console.log(
  `${files.length} READMEs follow the family structure; ${links} local references resolve (${relative(process.cwd(), root) || "."}).`,
);
