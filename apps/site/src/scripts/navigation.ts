/** Native links/disclosures remain usable without this small focus enhancement. */
const disclosures = document.querySelectorAll<HTMLDetailsElement>("details");
for (const details of disclosures) {
  details.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !details.open) return;
    details.open = false;
    details.querySelector("summary")?.focus();
    event.preventDefault();
  });
}

function hashTarget(hash: string): HTMLElement | null {
  try {
    return document.getElementById(decodeURIComponent(hash.slice(1)));
  } catch {
    return null;
  }
}
function markContents() {
  for (const link of document.querySelectorAll<HTMLAnchorElement>(".policy-contents a")) {
    if (link.hash === location.hash) link.setAttribute("aria-current", "location");
    else link.removeAttribute("aria-current");
  }
}
function focusTarget(target: HTMLElement) {
  if (!target.hasAttribute("tabindex")) target.tabIndex = -1;
  target.focus({ preventScroll: true });
}

document.addEventListener("click", (event) => {
  const link = (event.target as Element).closest<HTMLAnchorElement>("a[href]");
  if (
    !link ||
    event.button !== 0 ||
    event.metaKey ||
    event.ctrlKey ||
    event.shiftKey ||
    event.altKey ||
    link.target === "_blank"
  )
    return;
  const menu = link.closest<HTMLDetailsElement>("[data-navigation]");
  if (menu) {
    menu.open = false;
    menu.querySelector("summary")?.focus({ preventScroll: true });
  }
  if (
    link.origin === location.origin &&
    link.pathname === location.pathname &&
    link.search === location.search &&
    link.hash
  ) {
    const target = hashTarget(link.hash);
    if (target) {
      event.preventDefault();
      if (location.hash !== link.hash) history.pushState(null, "", link.hash);
      target.scrollIntoView();
      focusTarget(target);
      markContents();
    }
  }
});
function restoreHash() {
  markContents();
  const target = hashTarget(location.hash);
  if (target) {
    focusTarget(target);
    target.scrollIntoView();
  }
}
window.addEventListener("hashchange", restoreHash);
restoreHash();

const links = [...document.querySelectorAll<HTMLAnchorElement>("[data-nav-link]")];
const sections = [
  ...new Set(
    links.map((link) => hashTarget(link.hash)).filter((node): node is HTMLElement => Boolean(node)),
  ),
];
let frame = 0;
function updateCurrent() {
  frame = 0;
  const current = sections
    .filter((section) => section.getBoundingClientRect().top <= Math.min(innerHeight * 0.3, 180))
    .at(-1);
  for (const link of links) {
    if (current && link.hash === `#${current.id}`) link.setAttribute("aria-current", "location");
    else link.removeAttribute("aria-current");
  }
}
function requestUpdate() {
  if (!frame) frame = requestAnimationFrame(updateCurrent);
}
window.addEventListener("scroll", requestUpdate, { passive: true });
window.addEventListener("resize", requestUpdate, { passive: true });
updateCurrent();
