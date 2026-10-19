/** Run against the built site; use the same external Puppeteer module as test-air-site. */
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { tmpdir } from 'node:os';
const { default: puppeteer } = await import(process.env.PUPPETEER_MODULE || 'puppeteer-core');
const base = process.env.SITE_URL || 'http://127.0.0.1:8144';
const parent = process.env.AIR_EVIDENCE_DIR || tmpdir();
await mkdir(parent, { recursive: true });
const out = await mkdtemp(resolve(parent, 'cloakdrop-air-horizon-'));
console.log(`Evidence: ${out}`);
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true,
});
const results = [], errors = [];
try {
  for (const mode of ['normal', 'reduced', 'unsupported', 'constrained', 'save-data', 'forced', 'no-js']) {
    const context = await browser.createBrowserContext();
    const page = await context.newPage();
    const requests = [];
    page.on('request', r => requests.push(r.url()));
    page.on('pageerror', error => errors.push(String(error)));
    await page.setViewport({ width: 1440, height: 900 });
    if (mode === 'reduced') await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }]);
    if (mode === 'unsupported') await page.evaluateOnNewDocument(() => Object.defineProperty(navigator, 'gpu', { value: undefined }));
    if (mode === 'constrained') await page.evaluateOnNewDocument(() => Object.defineProperty(navigator, 'hardwareConcurrency', { value: 4 }));
    if (mode === 'save-data') await page.evaluateOnNewDocument(() => Object.defineProperty(navigator, 'connection', { value: { saveData: true, addEventListener() {}, removeEventListener() {} } }));
    if (mode === 'forced') {
      const cdp = await page.createCDPSession();
      await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'forced-colors', value: 'active' }] });
    }
    if (mode === 'no-js') await page.setJavaScriptEnabled(false);
    await page.goto(base, { waitUntil: 'networkidle0' });
    const field = () => page.$eval('.drop-horizon', e => ({ ...e.dataset }));
    const wait = (state) => page.waitForFunction(s => document.querySelector('.drop-horizon')?.dataset.lightState === s, { timeout: 15_000 }, state);
    assert.equal(await page.$eval('.drop-horizon', e => e.getAttribute('aria-hidden')), 'true');
    if (mode === 'normal') {
      await wait('idle');
      const initial = await field();
      assert.ok(Number(initial.lightFrames) > 0);
      assert.equal(initial.lightReady, 'true');
      await new Promise(r => setTimeout(r, 400));
      assert.equal((await field()).lightFrames, initial.lightFrames, 'No frames at rest');
      await page.mouse.move(1100, 300);
      await page.waitForFunction(n => Number(document.querySelector('.drop-horizon').dataset.lightFrames) > n, {}, Number(initial.lightFrames));
      await wait('idle');
      await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }]);
      await wait('idle');
      await page.screenshot({ path: resolve(out, 'live-dark.png') });
      await page.evaluate(() => scrollTo(0, document.body.scrollHeight));
      await wait('offscreen');
      assert.equal((await field()).lightReady, undefined);
      await page.evaluate(() => scrollTo(0, 0));
      await wait('idle');
      requests.length = 0;
      await Promise.all([page.waitForNavigation({ waitUntil: 'networkidle0' }), page.click('a[href="/privacy/"]')]);
      assert.equal(await page.$('.drop-horizon'), null);
      assert.ok(!requests.some(url => /air-light-shader/.test(url)), 'Policy loads no artwork renderer');
      await page.goBack({ waitUntil: 'networkidle0' });
      // Back restores the footer link's scroll position; the renderer stays released.
      assert.ok(await page.evaluate(() => scrollY > innerHeight));
      await wait('offscreen');
      assert.equal((await field()).lightReady, undefined);
      await page.evaluate(() => scrollTo(0, 0));
      await wait('idle');
      await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }]);
      await wait('reduced');
      assert.equal((await field()).lightReady, undefined);
      await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'no-preference' }]);
      await wait('idle');
      results.push({ mode, initial, restored: await field() });
    } else {
      if (mode !== 'no-js') await wait(mode === 'save-data' ? 'constrained' : mode);
      assert.ok(!requests.some(url => /air-light-shader/.test(url)), `${mode}: no shader request`);
      assert.equal(await page.$eval('.drop-horizon canvas', e => getComputedStyle(e).visibility), 'hidden');
      if (mode !== 'forced') assert.equal(await page.$eval('.drop-horizon svg', e => getComputedStyle(e).visibility), 'visible');
      results.push({ mode, state: await field() });
    }
    await context.close();
  }
  assert.deepEqual(errors, []);
  console.log('PASS real GPU arrival/pointer/idle/theme/offscreen/Back restoration/reduced lifecycle; six static fallback profiles; policy has no renderer.');
} finally {
  await writeFile(resolve(out, 'results.json'), JSON.stringify({ results, errors }, null, 2));
  await browser.close();
}
