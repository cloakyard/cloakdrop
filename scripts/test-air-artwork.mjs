/** Built pixel artwork acceptance; Puppeteer is external test tooling only. */
import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { tmpdir } from "node:os";
const { default: puppeteer } = await import(process.env.PUPPETEER_MODULE || "puppeteer-core");
const base = process.env.SITE_URL || "http://127.0.0.1:8168";
const parent = process.env.AIR_EVIDENCE_DIR || tmpdir();
await mkdir(parent, { recursive: true });
const output = await mkdtemp(resolve(parent, "cloakdrop-air-artwork-"));
console.log(`Evidence: ${output}`);
const browser = await puppeteer.launch({executablePath:process.env.CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",headless:true});
const evidence = {layouts:[],forms:[],lifecycle:[],errors:[]};
try {
  const page = await browser.newPage();
  page.on("pageerror", e => evidence.errors.push(String(e)));
  await page.emulateMediaFeatures([{name:"prefers-reduced-motion",value:"reduce"}]);
  await page.goto(base,{waitUntil:"networkidle0"});
  for(const [width,height] of [[320,568],[375,812],[390,844],[430,932],[639,800],[640,800],[641,800],[768,1024],[959,768],[960,768],[961,768],[1024,768],[1280,720],[1366,768],[1440,900],[1920,1080],[844,390]]) {
    await page.setViewport({width,height});
    for(const theme of ["light","dark"]) {
      await page.emulateMediaFeatures([{name:"prefers-reduced-motion",value:"reduce"},{name:"prefers-color-scheme",value:theme}]);
      for(const font of [16,32]) {
        const state = await page.evaluate(async font => {
          document.documentElement.style.fontSize=`${font}px`;
          await new Promise(requestAnimationFrame);
          const art=document.querySelector(".drop-artwork");
          const b=art.getBoundingClientRect();
          return {overflow:document.documentElement.scrollWidth>innerWidth+1,contained:b.left>=0&&b.right<=innerWidth+1,state:art.dataset.artState,count:art.querySelectorAll(".drop-pixel").length,animations:art.getAnimations({subtree:true}).length,hidden:art.querySelector(".drop-pixel-stage").getAttribute("aria-hidden"),controlHidden:art.querySelector("button").hidden};
        },font);
        assert.equal(state.overflow,false,JSON.stringify({width,height,theme,font,state}));
        assert.equal(state.contained,true);
        assert.equal(state.state,"reduced");
        assert.equal(state.count,149);
        assert.equal(state.animations,0);
        assert.equal(state.hidden,"true");
        assert.equal(state.controlHidden,true);
        evidence.layouts.push({width,height,theme,font,...state});
        if(font===16&&[320,390,1280,1440].includes(width)) await page.screenshot({path:resolve(output,`home-${width}-${theme}.png`),fullPage:true});
      }
    }
  }
  await page.close();
  for(const mode of ["normal","no-js","unsupported","constrained","save-data","forced"]) {
    const context=await browser.createBrowserContext();
    const p=await context.newPage();
    p.on("pageerror",e=>evidence.errors.push(String(e)));
    await p.setViewport({width:1440,height:1000});
    await p.evaluateOnNewDocument(()=>{
      Object.defineProperty(navigator,"hardwareConcurrency",{value:8,configurable:true});
      Object.defineProperty(navigator,"deviceMemory",{value:8,configurable:true});
    });
    if(mode==="no-js") await p.setJavaScriptEnabled(false);
    if(mode==="unsupported") await p.evaluateOnNewDocument(()=>{Element.prototype.animate=undefined;});
    if(mode==="constrained") await p.evaluateOnNewDocument(()=>Object.defineProperty(navigator,"deviceMemory",{value:4}));
    if(mode==="save-data") await p.evaluateOnNewDocument(()=>Object.defineProperty(navigator,"connection",{value:{saveData:true}}));
    if(mode==="forced") {
      const cdp=await p.createCDPSession();
      await cdp.send("Emulation.setEmulatedMedia",{features:[{name:"forced-colors",value:"active"}]});
    }
    await p.goto(base,{waitUntil:"networkidle0"});
    if(mode==="normal") {
      const stateIs = state => p.waitForFunction(state=>document.querySelector(".drop-artwork").dataset.artState===state,{},state);
      await stateIs("playing");
      const geometry=()=>p.$eval(".hero-actions",e=>{const b=e.getBoundingClientRect();return {x:b.x,y:b.y,width:b.width,height:b.height};});
      const before=await geometry();
      // Inspect every completed silhouette without slowing the regular test suite.
      for(const form of ["FILE","PKG","ISO","ZIP"]) {
        await p.waitForFunction(form=>{
          const art=document.querySelector(".drop-artwork");
          art.getAnimations({subtree:true}).forEach(a=>a.updatePlaybackRate(4));
          return art.querySelector(".drop-pixel-type").textContent===form&&art.getAnimations({subtree:true}).length===1;
        },{},form);
        await p.click(".drop-artwork button");
        await stateIs("paused");
        assert.equal(await p.$eval(".drop-artwork button", button =>
          getComputedStyle(button).color === getComputedStyle(document.querySelector("h1")).color), true,
          "The hovered pause/resume action must retain neutral Air ink");
        const count=await p.$$eval(".drop-pixel",nodes=>nodes.length);
        assert.ok(count>=70);
        await p.screenshot({path:resolve(output,`${form.toLowerCase()}-assembled.png`)});
        evidence.forms.push({form,count});
        await p.click(".drop-artwork button");
      }
      assert.deepEqual(await geometry(),before,"Animation must not move the download actions");
      await p.click(".drop-artwork button");
      await stateIs("paused");
      await p.waitForFunction(()=>document.querySelector(".drop-artwork").getAnimations({subtree:true}).every(a=>!a.pending));
      const time=()=>p.$eval(".drop-artwork",e=>e.getAnimations({subtree:true}).map(a=>a.currentTime));
      const paused=await time();
      await new Promise(r=>setTimeout(r,350));
      assert.deepEqual(await time(),paused);
      await p.evaluate(()=>dispatchEvent(new PageTransitionEvent("pagehide",{persisted:true})));
      await stateIs("hidden");
      await p.evaluate(()=>dispatchEvent(new PageTransitionEvent("pageshow",{persisted:true})));
      await stateIs("paused");
      await p.click(".drop-artwork button");
      await p.evaluate(()=>scrollTo(0,document.body.scrollHeight));
      await stateIs("offscreen");
      assert.equal(await p.$eval(".drop-artwork",e=>e.getAnimations({subtree:true}).every(a=>a.playState==="paused")),true);
      await p.evaluate(()=>scrollTo(0,0));
      await stateIs("playing");
      await p.emulateMediaFeatures([{name:"prefers-reduced-motion",value:"reduce"}]);
      await stateIs("reduced");
      assert.equal(await p.$eval(".drop-artwork",e=>e.getAnimations({subtree:true}).length),0);
      await p.emulateMediaFeatures([{name:"prefers-reduced-motion",value:"no-preference"}]);
      await stateIs("complete");
      await p.click(".drop-artwork button");
      await stateIs("playing");
      await p.goto(`${base}/privacy/`,{waitUntil:"networkidle0"});
      assert.equal(await p.$(".drop-artwork"),null);
      await p.goBack({waitUntil:"networkidle0"});
      await stateIs("playing");
      evidence.lifecycle.push("all silhouettes; fixed actions; pause time frozen; manual pause survives pagehide/pageshow; offscreen; reduced-motion cancel/replay; privacy/back");
    } else {
      if(mode!=="no-js") await p.waitForFunction(mode=>document.querySelector(".drop-artwork").dataset.artState===mode,{},mode);
      assert.equal(await p.$eval(".drop-artwork",e=>e.getAnimations({subtree:true}).length),0);
      assert.equal(await p.$$eval(".drop-pixel",nodes=>nodes.length),149);
      assert.equal(await p.$eval(".drop-artwork button",e=>e.hidden),true);
      evidence.lifecycle.push(mode);
    }
    await context.close();
  }
  assert.deepEqual(evidence.errors,[]);
  await writeFile(resolve(output,"results.json"),JSON.stringify(evidence,null,2));
  console.log(`PASS: ${evidence.layouts.length} layouts, ${evidence.forms.length} forms, pause/lifecycle and static fallbacks.`);
} finally {await browser.close();}
