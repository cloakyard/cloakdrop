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
  const MAX = 6.5;
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
  bars.forEach((b) => {
    b.style.transition = 'width 1s cubic-bezier(.2,.8,.2,1)';
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
function initMagnetic() {
  document.querySelectorAll<HTMLElement>('[data-magnetic]').forEach((btn) => {
    btn.style.transition = 'transform .25s cubic-bezier(.2,.8,.2,1)';
    btn.addEventListener('mousemove', (e) => {
      const r = btn.getBoundingClientRect();
      const dx = (e.clientX - r.left - r.width / 2) * 0.16;
      const dy = (e.clientY - r.top - r.height / 2) * 0.28;
      btn.style.transform = `translate(${dx}px, ${dy}px)`;
    });
    btn.addEventListener('mouseleave', () => {
      btn.style.transform = 'translate(0,0)';
    });
  });
}

/* -- Boot ------------------------------------------------------------------- */
if (!reduce) {
  // Reveal/count-up are scroll-driven, so they run on touch too; the rest is cursor-only.
  initReveal();
  initSheen();
  if (fine) {
    initTilt();
    initMagnetic();
  }
}
