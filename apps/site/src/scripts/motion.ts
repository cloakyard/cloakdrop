export {};

/**
 * Restrained progressive motion for the marketing page.
 * Product-specific animation lives with the transfer theatre; this file only
 * handles navigation state and a small, one-time content arrival.
 */

const motion = window.matchMedia('(prefers-reduced-motion: reduce)');

function initReveal() {
  if (!('IntersectionObserver' in window)) return;
  const animations = new Set<Animation>();
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      observer.unobserve(entry.target);
      if (motion.matches) return;
      // No persistent hidden styles: interrupted scripts, print, and no-JS remain legible.
      const animation = entry.target.animate(
        [{ opacity: .3, transform: 'translateY(12px)' }, { opacity: 1, transform: 'none' }],
        { duration: 550, easing: 'cubic-bezier(.22, 1, .36, 1)' }
      );
      animations.add(animation);
      animation.finished.then(() => animations.delete(animation)).catch(() => animations.delete(animation));
    });
  }, { threshold: .04 });
  document.querySelectorAll('[data-reveal]').forEach((element) => observer.observe(element));
  motion.addEventListener('change', () => {
    if (motion.matches) animations.forEach((animation) => animation.cancel());
  });
}

function initHeroArrival() {
  const hero = document.querySelector('[data-hero-arrival]');
  if (!hero || !('IntersectionObserver' in window)) return;
  const observer = new IntersectionObserver((entries) => {
    if (!entries.some((entry) => entry.isIntersecting)) return;
    observer.disconnect();
    if (motion.matches) return;
    hero.querySelectorAll<HTMLElement>('.track i').forEach((track, index) => {
      track.style.transformOrigin = 'left';
      const animation = track.animate(
        [{ transform: 'scaleX(.15)' }, { transform: 'scaleX(1)' }],
        { duration: 900, delay: index * 55, easing: 'cubic-bezier(.22, 1, .36, 1)' }
      );
      const stop = () => { if (motion.matches) animation.cancel(); };
      motion.addEventListener('change', stop);
      animation.finished.catch(() => {}).finally(() => motion.removeEventListener('change', stop));
    });
  }, { threshold: .15 });
  observer.observe(hero);
}

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

  const setActive = (id?: string) => {
    links.forEach((link) => {
      if (id && link.hash === `#${id}`) link.setAttribute('aria-current', 'true');
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
    }

    const marker = window.scrollY + Math.min(window.innerHeight * 0.3, 180);
    const current = sections.filter((section) => section.getBoundingClientRect().top + window.scrollY <= marker).at(-1);
    setActive(current?.id);
  };

  const requestUpdate = () => {
    if (!frame) frame = requestAnimationFrame(update);
  };

  update();
  window.addEventListener('scroll', requestUpdate, { passive: true });
  window.addEventListener('resize', requestUpdate, { passive: true });
}

function initMobileNavigation() {
  const panel = document.querySelector<HTMLElement>('#mobile-nav');
  if (!panel) return;
  panel.querySelectorAll<HTMLAnchorElement>('a').forEach((link) => {
    link.addEventListener('click', () => panel.hidePopover?.());
  });
}

initReveal();
initHeroArrival();
initNavigation();
initMobileNavigation();
