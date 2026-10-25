/** Production website acceptance. Set PUPPETEER_MODULE to an installed puppeteer-core
 * module URL when it is not locally resolvable; it is test tooling, never shipped.
 * Run after npm run build with SITE_URL pointing to Astro preview. No downloads/install. */
import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile, readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import { tmpdir } from "node:os";
const { default: puppeteer } = await import(process.env.PUPPETEER_MODULE || "puppeteer-core");
const base = process.env.SITE_URL || "http://127.0.0.1:8144";
const parent = process.env.AIR_EVIDENCE_DIR || tmpdir();
await mkdir(parent, { recursive: true });
const out = await mkdtemp(resolve(parent, "cloakdrop-air-site-"));
console.log(`Evidence: ${out}`);
const browser = await puppeteer.launch({
  executablePath:
    process.env.CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
});
const evidence = {
  browser: await browser.version(),
  layouts: [],
  journeys: [],
  screenshots: [],
  consoleErrors: [],
  foreignRequests: [],
};
const sizes = [
  [320, 568],
  [375, 812],
  [390, 844],
  [430, 932],
  [844, 390],
  [768, 1024],
  [1024, 768],
  [1280, 720],
  [1366, 768],
  [1440, 900],
  [1920, 1080],
  [639, 800],
  [640, 800],
  [641, 800],
  [767, 800],
  [769, 800],
  [959, 800],
  [960, 800],
  [961, 800],
  [1023, 768],
  [1025, 768],
  [1279, 800],
  [1281, 800],
];
const routes = ["/", "/privacy/", "/missing-air-review"];
let page;
async function screenshot(name, fullPage = true) {
  await page.screenshot({ path: `${out}/${name}.png`, fullPage });
  evidence.screenshots.push(`${name}.png`);
}
async function layout(state) {
  const result = await page.evaluate(() => {
    const visible = (node) =>
      node.getClientRects().length > 0 && getComputedStyle(node).visibility !== "hidden";
    const outside = [],
      small = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const node = walker.currentNode,
        parent = node.parentElement;
      if (
        !node.textContent.trim() ||
        !parent ||
        ["SCRIPT", "STYLE"].includes(parent.tagName) ||
        !visible(parent) ||
        parent.closest(".skip-link")
      )
        continue;
      const range = document.createRange();
      range.selectNodeContents(node);
      for (const rect of range.getClientRects())
        if (rect.width && (rect.left < -0.8 || rect.right > innerWidth + 0.8)) {
          outside.push({
            text: node.textContent.trim().slice(0, 70),
            left: rect.left,
            right: rect.right,
          });
          break;
        }
    }
    for (const node of document.querySelectorAll(
      ".site-header a, summary, .site-footer nav a, .text-link, .air-button, .policy-contents a",
    )) {
      if (!visible(node)) continue;
      const r = node.getBoundingClientRect();
      if (
        (matchMedia("(pointer:coarse)").matches || node.matches(".brand, summary")) &&
        (r.height < 43.9 || r.width < 43.9)
      )
        small.push({ text: node.textContent.trim(), w: r.width, h: r.height });
    }
    const mark = document.querySelector(".brand").getBoundingClientRect();
    const toggle = document.querySelector(".mobile-nav summary");
    const toggleRect = toggle.getBoundingClientRect();
    return {
      overflow: document.documentElement.scrollWidth > innerWidth + 1,
      outside,
      small,
      coarse: matchMedia("(pointer:coarse)").matches,
      menuOverlap: visible(toggle) && mark.right > toggleRect.left + 0.5,
      duplicateSource: visible(toggle) && visible(document.querySelector(".desktop-source")),
      footerCreditColourMatches: [...document.querySelectorAll(".site-footer p a")].every(
        (link) => getComputedStyle(link).color === getComputedStyle(
          matchMedia("(forced-colors: active)").matches
            ? document.querySelector(".site-footer nav a")
            : link.parentElement,
        ).color,
      ),
      nonNeutralLinks: matchMedia("(forced-colors: active)").matches ? [] : (() => {
        const probe = document.createElement("span");
        probe.style.setProperty("transition", "none", "important");
        document.body.append(probe);
        const colours = ["ink", "ink-secondary", "ink-muted", "action", "on-action"].map((token) => {
          probe.style.color = `var(--air-${token})`;
          return getComputedStyle(probe).color;
        });
        probe.remove();
        return [...document.querySelectorAll("a")].filter(visible)
          .filter((link) => !colours.includes(getComputedStyle(link).color))
          .map((link) => ({ label: link.textContent.trim(), colour: getComputedStyle(link).color }));
      })(),
      bodyBackground: getComputedStyle(document.body).backgroundColor,
      navigationColours: [...new Set([...document.querySelectorAll(
        ".desktop-nav a, .desktop-source, .mobile-nav nav a",
      )].filter(visible).map((link) => getComputedStyle(link).color))],
      visibleH1: [...document.querySelectorAll("h1")].filter(visible).length,
      brokenImages: [...document.images]
        .filter((i) => !i.complete || !i.naturalWidth)
        .map((i) => i.src),
    };
  });
  evidence.layouts.push({ ...state, ...result });
  assert.equal(result.overflow, false, `${JSON.stringify(state)} document overflow`);
  assert.deepEqual(result.outside, [], `${JSON.stringify(state)} text bounds`);
  assert.deepEqual(result.small, [], `${JSON.stringify(state)} target sizes`);
  assert.equal(result.menuOverlap, false, `${JSON.stringify(state)} menu overlaps brand`);
  assert.ok(result.navigationColours.length <= 1, `${JSON.stringify(state)} navigation colour drift`);
  assert.equal(result.duplicateSource, false, `${JSON.stringify(state)} duplicate compact navigation`);
  assert.ok(result.footerCreditColourMatches, `${JSON.stringify(state)} footer credit colour drift`);
  assert.deepEqual(result.nonNeutralLinks, [], `${JSON.stringify(state)} content link colour drift`);
  assert.equal(result.visibleH1, 1);
  assert.deepEqual(result.brokenImages, []);
}
async function setup(width, height, theme, root = 16) {
  await page.setViewport({ width, height, hasTouch: width <= 1100, isMobile: false });
  await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: theme }]);
  await page.evaluate((size) => {
    document.documentElement.style.fontSize = `${size}px`;
    document.querySelector("[data-navigation]").open = false;
  }, root);
  await page.evaluate(() => new Promise(requestAnimationFrame));
}
async function contrast() {
  return page.evaluate(() => {
    const rgb = (c) => {
      const a = c.match(/[\d.]+/g)?.map(Number);
      return a && a.length >= 3 ? a : null;
    };
    const lum = (c) =>
      c
        .slice(0, 3)
        .map((x) => {
          x /= 255;
          return x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4;
        })
        .reduce((s, x, i) => s + x * [0.2126, 0.7152, 0.0722][i], 0);
    let tested = 0;
    const failures = [];
    for (const node of document.querySelectorAll("body *")) {
      if (
        !node.getClientRects().length ||
        getComputedStyle(node).visibility === "hidden" ||
        !Array.from(node.childNodes).some((n) => n.nodeType === 3 && n.textContent.trim())
      )
        continue;
      const style = getComputedStyle(node);
      if (["SCRIPT", "STYLE"].includes(node.tagName)) continue;
      let bgNode = node,
        bg;
      while (bgNode) {
        const c = rgb(getComputedStyle(bgNode).backgroundColor);
        if (c && (c.length === 3 || c[3] === 1)) {
          bg = c;
          break;
        }
        bgNode = bgNode.parentElement;
      }
      const fg = rgb(style.color);
      if (!bg || !fg) continue;
      const ratio = (Math.max(lum(bg), lum(fg)) + 0.05) / (Math.min(lum(bg), lum(fg)) + 0.05);
      const threshold = parseFloat(style.fontSize) >= 24 ? 3 : 4.5;
      tested++;
      if (ratio + 0.01 < threshold)
        failures.push({ text: node.textContent.slice(0, 70), ratio, threshold });
    }
    return { tested, failures };
  });
}
try {
  page = await browser.newPage();
  await page.setCacheEnabled(false);
  page.on("pageerror", (error) => evidence.consoleErrors.push(error.message));
  page.on("request", (req) => {
    if (!req.url().startsWith(base) && !req.url().startsWith("data:"))
      evidence.foreignRequests.push(req.url());
  });
  for (const route of routes)
    for (const theme of ["light", "dark"]) {
      const response = await page.goto(base + route, { waitUntil: "networkidle0" });
      assert.equal(response.status(), route.includes("missing") ? 404 : 200);
      for (const [width, height] of sizes)
        for (const root of [16, 32]) {
          await setup(width, height, theme, root);
          await layout({ route, theme, width, height, root, state: "closed" });
          if (await page.$eval(".mobile-nav", (n) => getComputedStyle(n).display !== "none")) {
            await page.$eval("[data-navigation]", (n) => (n.open = true));
            await layout({ route, theme, width, height, root, state: "open" });
          }
        }
      await setup(1440, 900, theme);
      const colours = await contrast();
      assert.deepEqual(colours.failures, []);
      evidence.journeys.push({ check: "text contrast", route, theme, ...colours });
      for (const [width, height] of [
        [1440, 900],
        [1280, 720],
        [768, 1024],
        [390, 844],
        [320, 568],
      ]) {
        await setup(width, height, theme);
        await page.evaluate(() => scrollTo(0, 0));
        await screenshot(
          `${route === "/" ? "home" : route.includes("privacy") ? "privacy" : "404"}-${width}-${theme}`,
          !route.includes("privacy"),
        );
      }
    }
  // Actual pointer/keyboard journeys from each route, at desktop and phone widths.
  for (const route of routes)
    for (const [width, height, theme] of [
      [1280, 720, "light"],
      [390, 844, "dark"],
    ]) {
      for (const hash of ["product", "provenance", "privacy", "download"]) {
        await page.goto(base + route, { waitUntil: "networkidle0" });
        await setup(width, height, theme);
        const nav = width < 640 ? ".mobile-nav" : ".desktop-nav";
        if (width < 640) await page.click(".mobile-nav summary");
        await page.click(`${nav} a[href$="#${hash}"]`);
        await page.waitForFunction(
          (hash) => location.hash === `#${hash}` && document.activeElement?.id === hash,
          {},
          hash,
        );
        const result = await page.evaluate(
          (hash) => ({
            hash: location.hash,
            focused: document.activeElement.id,
            top: document.getElementById(hash).getBoundingClientRect().top,
            menuOpen: document.querySelector("[data-navigation]").open,
          }),
          hash,
        );
        assert.equal(result.menuOpen, false);
        assert.ok(result.top >= -1);
        evidence.journeys.push({ check: "header destination", route, width, ...result });
      }
    }
  await page.goto(base, { waitUntil: "networkidle0" });
  await setup(390, 844, "dark");
  await page.focus(".mobile-nav summary");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Tab");
  assert.equal(await page.$eval("[data-navigation]", (n) => n.open), true);
  assert.equal(await page.evaluate(() => document.activeElement.textContent.trim()), "Product");
  await screenshot("menu-390-dark", false);
  await page.keyboard.press("Escape");
  assert.equal(await page.$eval("[data-navigation]", (n) => n.open), false);
  assert.equal(await page.evaluate(() => document.activeElement.tagName), "SUMMARY");
  await page.keyboard.press("Space");
  assert.equal(await page.$eval("[data-navigation]", (n) => n.open), true);
  await page.keyboard.press("Escape");
  await page.goto(base, { waitUntil: "networkidle0" });
  await page.keyboard.press("Tab");
  assert.equal(
    await page.evaluate(() => document.activeElement.classList.contains("skip-link")),
    true,
  );
  const skipContrast = await contrast();
  assert.deepEqual(skipContrast.failures, []);
  await page.keyboard.press("Enter");
  assert.equal(await page.evaluate(() => document.activeElement.id), "main");
  await page.keyboard.press("Tab");
  if (await page.evaluate(() => document.activeElement.matches(".drop-artwork button"))) {
    await page.keyboard.press("Enter");
    assert.equal(await page.$eval(".drop-artwork button", (n) => n.textContent), "Play animation");
    await page.keyboard.press("Space");
    assert.equal(await page.$eval(".drop-artwork button", (n) => n.textContent), "Pause animation");
    await page.keyboard.press("Tab");
  }
  assert.equal(await page.evaluate(() => document.activeElement.getAttribute("href")), "#download");
  evidence.journeys.push({
    check: "keyboard disclosure Enter/Space/Tab/Escape and skip link",
    pass: true,
  });
  // Privacy source sections and policy revision remain intact; anchors move focus.
  await page.goto(base + "/privacy/", { waitUntil: "networkidle0" });
  await setup(390, 844, "light");
  const source = await readFile(new URL("../PRIVACY.md", import.meta.url), "utf8");
  const sections = [...source.matchAll(/^## (.+)$/gm)].map((match) => match[1]);
  assert.deepEqual(
    await page.$$eval(".policy-document h2", (nodes) => nodes.map((n) => n.textContent)),
    sections,
  );
  assert.equal(await page.$eval("time", (n) => n.dateTime), "2026-09-06");
  for (const link of await page.$$eval(".policy-contents a", (nodes) =>
    nodes.map((n) => n.getAttribute("href")),
  )) {
    await page.click(`.policy-contents a[href="${link}"]`);
    assert.equal(await page.evaluate(() => document.activeElement.id), link.slice(1));
  }
  await page.focus(".policy-contents summary");
  await page.keyboard.press("Escape");
  assert.equal(await page.$eval(".policy-contents", (n) => n.open), false);
  await page.keyboard.press("Enter");
  assert.equal(await page.$eval(".policy-contents", (n) => n.open), true);
  evidence.journeys.push({
    check: "all source policy headings, nine contents anchors, revision and disclosure",
    sections: sections.length,
    sourceSha256: createHash("sha256").update(source).digest("hex"),
  });
  await page.goto(base + "/missing-air-review", { waitUntil: "networkidle0" });
  assert.equal(await page.$eval('meta[name="robots"]', (n) => n.content), "noindex");
  await page.click("main .air-button");
  await page.waitForFunction(() => location.pathname === "/");
  // Same-page navigation preserves history, repeated activation and keyboard continuation.
  await page.goto(base, { waitUntil: "networkidle0" });
  await setup(1280, 720, "light");
  await page.click('.desktop-nav a[href="#product"]');
  await page.click('.desktop-nav a[href="#download"]');
  await page.goBack();
  await page.waitForFunction(
    () => location.hash === "#product" && document.activeElement.id === "product",
  );
  await page.goForward();
  await page.waitForFunction(
    () => location.hash === "#download" && document.activeElement.id === "download",
  );
  await page.click('.desktop-nav a[href="#download"]');
  await page.keyboard.press("Tab");
  assert.equal(
    await page.evaluate(() => document.activeElement.href),
    "https://github.com/cloakyard/cloakdrop/releases",
  );
  evidence.journeys.push({
    check: "anchor Back/Forward, repeated destination and next keyboard action",
    pass: true,
  });
  // No invented release URL, changed signing guidance or changed supported platform.
  const install = await page.$eval("#download", (n) => n.textContent);
  for (const text of [
    "Apple silicon",
    "macOS 26 or later",
    "locally signed",
    "not notarized",
    "Open Anyway",
    "release preparation",
  ])
    assert.ok(install.includes(text), text);
  assert.equal(
    await page.$eval("#download .air-button", (n) => n.href),
    "https://github.com/cloakyard/cloakdrop/releases",
  );
  for (const path of [
    "/hero.png",
    "/hero.webp",
    "/cloakdrop-mark.svg",
    "/icons/favicon.svg",
    "/favicon.png",
    "/apple-touch-icon.png",
    "/og.png",
    "/sitemap-index.xml",
    "/robots.txt",
  ]) {
    const response = await fetch(base + path);
    assert.equal(response.status, 200, path);
    if (path === "/og.png") {
      const png = Buffer.from(await response.arrayBuffer());
      assert.equal(png.readUInt32BE(16), 1200);
      assert.equal(png.readUInt32BE(20), 630);
    }
  }
  assert.equal(
    await page.$eval('meta[property="og:title"]', (n) => n.content),
    "CloakDrop — Your downloads. Under control.",
  );
  assert.equal(
    await page.$eval('link[rel="canonical"]', (n) => n.href),
    "https://drop.cloakyard.com/",
  );
  evidence.journeys.push({
    check: "404 home recovery, accurate install/release links, metadata and nine built assets",
    pass: true,
  });
  await page.goto(base + "/#%E0%A4%A", { waitUntil: "networkidle0" });
  assert.equal(await page.$eval("main", (n) => Boolean(n)), true);
  // Reduced motion and forced colours are separate from regular theme captures.
  await setup(390, 844, "light");
  const media = await page.createCDPSession();
  for (const feature of [
    { name: "prefers-reduced-motion", value: "reduce" },
    { name: "forced-colors", value: "active" },
  ]) {
    await media.send("Emulation.setEmulatedMedia", { features: [feature] });
    await page.goto(base, { waitUntil: "networkidle0" });
    await page.click(".mobile-nav summary");
    await layout({ route: "/", width: 390, root: 16, state: feature.name });
    assert.equal(await page.evaluate(() => document.getAnimations().length), 0);
    await screenshot(feature.name, false);
  }
  await media.send("Emulation.setEmulatedMedia", { features: [] });
  await media.detach();
  await page.emulateMediaFeatures([]);
  assert.equal(await page.evaluate(() => matchMedia("(forced-colors: active)").matches), false);
  // No JavaScript: the native menu is in document flow and all routes/actions remain usable.
  await page.setJavaScriptEnabled(false);
  for (const route of routes) {
    await page.goto(base + route, { waitUntil: "networkidle0" });
    await page.click(".mobile-nav summary");
    await layout({ route, width: 390, root: 16, state: "no-js open" });
    if (route === "/") {
      await page.click('.mobile-nav a[href="#download"]');
      assert.ok(page.url().endsWith("#download"));
      await screenshot("no-js-download-390", false);
    }
  }
  await page.setJavaScriptEnabled(true);
  // Longer navigation labels must reflow without hiding a destination.
  await page.goto(base, { waitUntil: "networkidle0" });
  await setup(320, 568, "light", 32);
  await page.evaluate(() => {
    document.querySelector("[data-navigation]").open = true;
    document.querySelector(".mobile-nav a").textContent =
      "Product features and download capabilities";
  });
  await layout({ route: "/", width: 320, root: 32, state: "long label" });
  await screenshot("menu-long-label-320-200text", false);
  assert.deepEqual(evidence.consoleErrors, []);
  assert.deepEqual(evidence.foreignRequests, []);
  console.log(
    `PASS ${evidence.layouts.length} layouts; ${evidence.journeys.length} journey records; ${evidence.screenshots.length} captures; no script errors or foreign runtime requests.`,
  );
} finally {
  await writeFile(`${out}/website.json`, JSON.stringify(evidence, null, 2) + "\n");
  await browser.close();
}
