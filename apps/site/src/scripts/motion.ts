/**
 * Progressive motion layer for the marketing page.
 *
 * Every effect here is additive: the page is fully readable with JS disabled and
 * with `prefers-reduced-motion: reduce`. Nothing is hidden by CSS — the reveal
 * pass only dims an element *after* it has confirmed it will animate it back in,
 * so a script failure can never leave content invisible.
 */

const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
// The tilt/glare/magnet effects are cursor-driven; they mean nothing on touch.
const fine = window.matchMedia('(hover: hover) and (pointer: fine)').matches;

/* -- Hero: 3D cursor tilt + glare ------------------------------------------- */
function initTilt() {
  const tilt = document.querySelector<HTMLElement>('[data-tilt]');
  const scene = tilt?.parentElement;
  if (!tilt || !scene) return;

  const glare = document.querySelector<HTMLElement>('[data-glare]');
  const MAX = 4;
  let raf = 0;
  let rx = 0;
  let ry = 0;
  let gx = 50;
  let gy = 40;

  const apply = () => {
    raf = 0;
    tilt.style.transform = `rotateX(${rx.toFixed(2)}deg) rotateY(${ry.toFixed(2)}deg)`;
    if (glare) {
      glare.style.background = `radial-gradient(circle at ${gx.toFixed(1)}% ${gy.toFixed(1)}%, rgba(255,255,255,0.30), transparent 42%)`;
    }
  };

  scene.addEventListener('mousemove', (e) => {
    const r = scene.getBoundingClientRect();
    const px = (e.clientX - r.left) / r.width;
    const py = (e.clientY - r.top) / r.height;
    ry = (px - 0.5) * 2 * MAX;
    rx = -(py - 0.5) * 2 * MAX;
    gx = px * 100;
    gy = py * 100;
    if (!raf) raf = requestAnimationFrame(apply);
  });

  scene.addEventListener('mouseenter', () => {
    tilt.style.transition = 'transform .14s ease-out';
    if (glare) glare.style.opacity = '1';
  });

  scene.addEventListener('mouseleave', () => {
    tilt.style.transition = 'transform .6s cubic-bezier(.2,.8,.2,1)';
    tilt.style.transform = 'rotateX(0deg) rotateY(0deg)';
    if (glare) glare.style.opacity = '0';
  });
}

/* -- Hero: sheen sweep ------------------------------------------------------ */
function initSheen() {
  const sheen = document.querySelector<HTMLElement>('[data-sheen]');
  const scene = document.querySelector<HTMLElement>('[data-tilt]')?.parentElement;
  if (!sheen) return;

  const fire = () => {
    sheen.style.animation = 'none';
    void sheen.offsetWidth; // reflow, so re-adding the animation restarts it
    sheen.style.animation = 'cd-sheen 1.15s cubic-bezier(.4,.1,.2,1)';
  };

  window.setTimeout(fire, 900);
  if (fine && scene) scene.addEventListener('mouseenter', fire);
}

/* -- Spec strip: count-up --------------------------------------------------- */
function runCount(el: HTMLElement) {
  const to = Number(el.dataset.countTo);
  if (!Number.isFinite(to)) return;
  const pre = el.dataset.countPrefix ?? '';
  const suf = el.dataset.countSuffix ?? '';
  const comma = 'countComma' in el.dataset;
  const dur = 1200;
  const t0 = performance.now();

  const fmt = (n: number) =>
    pre + (comma ? Math.round(n).toLocaleString('en-US') : String(Math.round(n))) + suf;

  const step = (t: number) => {
    const p = Math.min(1, (t - t0) / dur);
    el.textContent = fmt(to * (1 - Math.pow(1 - p, 3)));
    if (p < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

/* -- Scroll reveal (drives count-ups and segment bars) ---------------------- */
function initReveal() {
  const revs = Array.from(document.querySelectorAll<HTMLElement>('[data-reveal]'));
  const bars = Array.from(document.querySelectorAll<HTMLElement>('[data-segw]'));
  if (!('IntersectionObserver' in window)) return;

  revs.forEach((el) => {
    el.style.opacity = '0';
    el.style.transform = 'translateY(26px)';
    el.style.transition = 'opacity .7s ease, transform .8s cubic-bezier(.2,.8,.2,1)';
  });
  bars.forEach((b, i) => {
    // Each segment fills at its own pace, so they never land in lockstep.
    const dur = 0.85 + ((i * 0.37) % 0.5);
    b.style.transition = `width ${dur.toFixed(2)}s cubic-bezier(.2,.8,.2,1)`;
    b.style.width = '0%';
  });

  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((en) => {
        if (!en.isIntersecting) return;
        const el = en.target as HTMLElement;
        el.style.opacity = '1';
        el.style.transform = 'none';

        el.querySelectorAll<HTMLElement>('[data-count-to]').forEach((c) => {
          if (c.dataset.countDone) return;
          c.dataset.countDone = '1';
          runCount(c);
        });

        el.querySelectorAll<HTMLElement>('[data-segw]').forEach((b, i) => {
          window.setTimeout(() => {
            b.style.width = b.dataset.segw!;
          }, 120 + i * 75);
        });

        io.unobserve(el);
      });
    },
    { threshold: 0.16 }
  );

  revs.forEach((el) => io.observe(el));
}

/* -- Magnetic buttons ------------------------------------------------------- */
/** Max px a button leans toward the cursor, per axis, reached at its very edge. */
const MAGNET_SHIFT = 3;

// A lean, not a chase. The offset is normalised against each button's own size, so a wide
// button doesn't travel further than a narrow one, and both axes share one cap — pulling
// harder vertically only makes a button look loose. Keep the transition short too: the
// further the transform lags the pointer, the more the button reads as bouncy rather than
// responsive. It's a click target first.
function initMagnetic() {
  document.querySelectorAll<HTMLElement>('[data-magnetic]').forEach((btn) => {
    btn.style.transition = 'transform .18s cubic-bezier(.2,.8,.2,1)';
    btn.addEventListener('mousemove', (e) => {
      const r = btn.getBoundingClientRect();
      // −1…+1 across the button, so the shift maxes out at MAGNET_SHIFT on either edge.
      const dx = ((e.clientX - r.left) / r.width - 0.5) * 2 * MAGNET_SHIFT;
      const dy = ((e.clientY - r.top) / r.height - 0.5) * 2 * MAGNET_SHIFT;
      btn.style.transform = `translate(${dx.toFixed(2)}px, ${dy.toFixed(2)}px)`;
    });
    btn.addEventListener('mouseleave', () => {
      btn.style.transform = 'translate(0,0)';
    });
  });
}

/* -- Product workflow tabs ------------------------------------------------- */
function initProductTabs() {
  const root = document.querySelector<HTMLElement>('[data-product-experience]');
  if (!root) return;

  const tabs = Array.from(root.querySelectorAll<HTMLButtonElement>('[data-story-tab]'));
  const panels = Array.from(root.querySelectorAll<HTMLElement>('[data-story-panel]'));
  if (!tabs.length || !panels.length) return;

  const activate = (tab: HTMLButtonElement, moveFocus = false) => {
    const key = tab.dataset.storyTab;
    tabs.forEach((candidate) => {
      const selected = candidate === tab;
      candidate.setAttribute('aria-selected', selected ? 'true' : 'false');
      candidate.tabIndex = selected ? 0 : -1;
    });
    panels.forEach((panel) => {
      panel.hidden = panel.dataset.storyPanel !== key;
    });
    if (moveFocus) tab.focus();
  };

  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => activate(tab));
    tab.addEventListener('keydown', (event) => {
      let next = index;
      if (event.key === 'ArrowRight' || event.key === 'ArrowDown') next = (index + 1) % tabs.length;
      else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') next = (index - 1 + tabs.length) % tabs.length;
      else if (event.key === 'Home') next = 0;
      else if (event.key === 'End') next = tabs.length - 1;
      else return;
      event.preventDefault();
      activate(tabs[next]!, true);
    });
  });
}

/* -- Navigation state + useful scroll progress ----------------------------- */
function initNavigation() {
  const links = Array.from(document.querySelectorAll<HTMLAnchorElement>('[data-nav-link]'));
  const progress = document.querySelector<HTMLElement>('[data-scroll-progress]');
  const sections = Array.from(
    new Set(
      links
        .map((link) => link.hash)
        .filter(Boolean)
        .map((hash) => document.querySelector<HTMLElement>(hash))
        .filter((section): section is HTMLElement => Boolean(section))
    )
  );

  const setActive = (id: string) => {
    links.forEach((link) => {
      if (link.hash === `#${id}`) link.setAttribute('aria-current', 'true');
      else link.removeAttribute('aria-current');
    });
  };

  let frame = 0;
  const update = () => {
    frame = 0;
    if (progress) {
      const max = document.documentElement.scrollHeight - window.innerHeight;
      const ratio = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
      progress.style.transform = `scaleX(${ratio.toFixed(4)})`;
    };

    const marker = window.scrollY + Math.min(window.innerHeight * 0.3, 180);
    const current = sections.filter((section) => section.offsetTop <= marker).at(-1);
    if (current) setActive(current.id);
    else links.forEach((link) => link.removeAttribute('aria-current'));
  };
  const onScroll = () => {
    if (!frame) frame = requestAnimationFrame(update);
  };
  update();
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll, { passive: true });
}

/* -- Mobile popover handoff ------------------------------------------------ */
function initMobileNavigation() {
  const panel = document.querySelector<HTMLElement>('#mobile-nav');
  if (!panel) return;
  panel.querySelectorAll<HTMLAnchorElement>('a').forEach((link) => {
    link.addEventListener('click', () => panel.hidePopover?.());
  });
}

/* -- Boot ------------------------------------------------------------------- */
initProductTabs();
initNavigation();
initMobileNavigation();

if (!reduce) {
  // Reveal/count-up are scroll-driven, so they run on touch too; the rest is cursor-only.
  initReveal();
  initSheen();
  if (fine) {
    initTilt();
    initMagnetic();
  }
}
