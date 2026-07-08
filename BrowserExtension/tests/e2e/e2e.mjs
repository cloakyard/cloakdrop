// E2E smoke for the CloakDrop extension in Chrome for Testing, using raw CDP over Node's
// built-in WebSocket (no dependencies). Asserts the deduped sniffer list, the in-page pill,
// and the interception → bypass re-download path (native host absent under this profile).
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const CHROME = process.argv[2];
const EXT = process.argv[3];
const PORT = Number(process.argv[4] || 8877);
const ORIGIN = `http://127.0.0.1:${PORT}`;
const DEBUG_PORT = 9333;

// A stale browser holding the debug port would make every later step silently probe the wrong
// instance — fail fast instead.
try {
  await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/version`);
  console.error(`E2E error: something already listens on debug port ${DEBUG_PORT} — kill it first`);
  process.exit(1);
} catch (_) { /* free — good */ }

const profile = mkdtempSync(join(tmpdir(), "cloakdrop-e2e-"));
const chrome = spawn(CHROME, [
  `--user-data-dir=${profile}`,
  `--load-extension=${EXT}`,
  `--remote-debugging-port=${DEBUG_PORT}`,
  "--headless=new",
  "--no-first-run", "--no-default-browser-check", "--disable-sync",
  "about:blank"
], { stdio: "ignore" });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, label) => {
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}`);
  if (!ok) failures++;
};

async function json(path) {
  const res = await fetch(`http://127.0.0.1:${DEBUG_PORT}${path}`, { method: path.startsWith("/json/new") ? "PUT" : "GET" });
  return res.json();
}

// Minimal CDP client over one WS connection.
class CDP {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); }
  static async connect(url) {
    const ws = new WebSocket(url);
    await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
    const c = new CDP(ws);
    ws.onmessage = (e) => {
      const msg = JSON.parse(e.data);
      if (msg.id && c.pending.has(msg.id)) { c.pending.get(msg.id)(msg); c.pending.delete(msg.id); }
    };
    return c;
  }
  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve) => this.pending.set(id, resolve));
  }
  async eval(expression) {
    const r = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails));
    return r.result?.result?.value;
  }
  close() { this.ws.close(); }
}

try {
  // Wait for the debugger endpoint and the extension service worker.
  let sw = null;
  for (let i = 0; i < 50 && !sw; i++) {
    await sleep(200);
    try {
      const targets = await json("/json/list");
      sw = targets.find((t) => t.type === "service_worker" && t.url.includes("background.js"));
    } catch (_) { /* not up yet */ }
  }
  if (!sw) throw new Error("extension service worker never appeared");

  // Keep the service worker demonstrably awake through page load: this test asserts the
  // classifier pipeline, not MV3 cold-start wake latency (whose misses the popup's DOM scan
  // and storage.session persistence mitigate in real use).
  const warm = await CDP.connect(sw.webSocketDebuggerUrl);
  await warm.eval("1");
  const keepAlive = setInterval(() => warm.eval("1").catch(() => {}), 500);

  // Open the test page and let its fetches run.
  await json(`/json/new?${encodeURIComponent(ORIGIN + "/")}`);
  await sleep(2500);

  const cdp = await CDP.connect(sw.webSocketDebuggerUrl);

  // 1) The deduped, collapsed sniffer list for the test tab.
  const list = await cdp.eval(`
    chrome.tabs.query({ url: "${ORIGIN}/*" })
      .then((tabs) => restored.then(() => mediaList(tabs[0].id)))
      .then((items) => items.map((i) => ({ type: i.type, url: i.url })))
  `);
  const urls = list.map((i) => i.url);
  const ofType = (t) => list.filter((i) => i.type === t);
  check(ofType("stream").length === 1 && urls.some((u) => u.endsWith("video.m3u8")),
    `HLS+DASH twin collapsed to one stream, HLS wins (got ${JSON.stringify(urls)})`);
  check(urls.filter((u) => u.includes("movie.mp4")).length === 1,
    "token-rotated movie.mp4 recorded once");
  check(!urls.some((u) => u.includes("success.mp3")), "UI sound filtered out");
  check(list.some((i) => i.type === "file" && i.url.includes("/api/export")),
    "attachment export sniffed as a file");
  check(urls.some((u) => u.includes("direct.mp4")), "direct <video> file sniffed");

  // 2) The in-page pill: exactly one (on the main player; the src-less preview gets none).
  const pageTargets = await json("/json/list");
  const page = pageTargets.find((t) => t.type === "page" && t.url.startsWith(ORIGIN));
  const pageCdp = await CDP.connect(page.webSocketDebuggerUrl);
  const pills = await pageCdp.eval(`
    [...document.querySelectorAll("div")].filter((d) => d.shadowRoot && d.shadowRoot.querySelector(".pill")).length
  `);
  check(pills === 1, `exactly one Save pill on the page (got ${pills})`);
  pageCdp.close();

  // 3) Interception: navigating to a zip triggers a download; with no native host reachable the
  // extension must cancel, then give it back to the browser (bypass) — never lose the file.
  await json(`/json/new?${encodeURIComponent(ORIGIN + "/files/tool.zip")}`);
  await sleep(2500);
  const downloads = await cdp.eval(`
    chrome.downloads.search({}).then((ds) => ds.map((d) => ({
      url: d.finalUrl || d.url, state: d.state, exists: d.exists
    })))
  `);
  const zips = downloads.filter((d) => d.url.includes("tool.zip"));
  check(zips.length === 1 && zips[0].state !== "interrupted",
    `intercepted zip re-issued to the browser once (got ${JSON.stringify(downloads)})`);

  clearInterval(keepAlive);
  warm.close();
  cdp.close();
} catch (error) {
  console.error("E2E error:", error.message);
  failures++;
} finally {
  chrome.kill("SIGKILL");   // .app binaries re-exec helpers; TERM on the child can leave them alive
  await sleep(300);
  rmSync(profile, { recursive: true, force: true });
}
process.exit(failures ? 1 : 0);
