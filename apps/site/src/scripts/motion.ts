/**
 * Restrained progressive motion for the marketing page.
 * Product-specific animation lives with the transfer theatre; this file only
 * handles navigation state and a small, one-time content arrival.
 */

const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

function initReveal() {
  if (reduce || !('IntersectionObserver' in window)) return;

  const elements = Array.from(document.querySelectorAll<HTMLElement>('[data-reveal]'));
  elements.forEach((element) => {
    element.style.opacity = '0';
    element.style.transform = 'translateY(12px)';
    element.style.transition =
      'opacity .55s ease, transform .7s cubic-bezier(.22, 1, .36, 1)';
  });

  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        const element = entry.target as HTMLElement;
        element.style.opacity = '1';
        element.style.transform = 'none';
        observer.unobserve(element);
      });
    },
    // Some mobile chapters are deliberately tall; a low ratio reveals the shell
    // as soon as its opening scene arrives instead of waiting for hundreds of
    // pixels of an otherwise blank panel to enter the viewport.
    { threshold: 0.04, rootMargin: '0px 0px -6% 0px' }
  );

  elements.forEach((element) => observer.observe(element));
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
    const current = sections.filter((section) => section.offsetTop <= marker).at(-1);
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
initNavigation();
initMobileNavigation();
