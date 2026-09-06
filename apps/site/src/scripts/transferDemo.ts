export {};

/** A finite, user-started illustration. No network requests or real download state. */
const motion = window.matchMedia('(prefers-reduced-motion: reduce)');

document.querySelectorAll<HTMLElement>('[data-transfer-theatre]').forEach((root) => {
  const tabs = Array.from(root.querySelectorAll<HTMLButtonElement>('[data-chapter-tab]'));
  const panels = Array.from(root.querySelectorAll<HTMLElement>('[data-chapter-panel]'));
  const simulation = root.querySelector<HTMLElement>('[data-simulation]');
  const start = root.querySelector<HTMLButtonElement>('[data-simulate]');
  const label = root.querySelector<HTMLElement>('[data-simulate-label]');
  const resetButton = root.querySelector<HTMLButtonElement>('[data-reset]');
  const phase = root.querySelector<HTMLElement>('[data-phase-text]');
  if (!simulation || !start || !label || !resetButton || !phase) return;

  let timers: number[] = [];
  const clearTimers = () => {
    timers.forEach(window.clearTimeout);
    timers = [];
  };
  const setPhase = (state: string, text: string) => {
    simulation.dataset.simState = state;
    phase.textContent = text;
  };
  const reset = () => {
    clearTimers();
    simulation.classList.add('is-resetting');
    setPhase('idle', 'Ready when you are.');
    // Flush the reset width before replay; otherwise CSS animates backward from 100%.
    simulation.getBoundingClientRect();
    simulation.classList.remove('is-resetting');
    start.disabled = false;
    label.textContent = 'Try a relaunch';
    resetButton.disabled = true;
  };
  const complete = () => {
    clearTimers();
    setPhase('complete', 'Demo complete. Saved ranges resumed.');
    start.disabled = false;
    label.textContent = 'Play it again';
  };
  const showChapter = (key: string, focus = false) => {
    reset();
    tabs.forEach((tab) => {
      const selected = tab.dataset.chapterTab === key;
      tab.setAttribute('aria-selected', String(selected));
      tab.tabIndex = selected ? 0 : -1;
      if (focus && selected) tab.focus();
    });
    panels.forEach((panel) => { panel.hidden = panel.dataset.chapterPanel !== key; });
  };

  tabs.forEach((tab, index) => {
    tab.disabled = false;
    tab.addEventListener('click', () => showChapter(tab.dataset.chapterTab!));
    tab.addEventListener('keydown', (event) => {
      let next: number;
      if (event.key === 'ArrowRight' || event.key === 'ArrowDown') next = (index + 1) % tabs.length;
      else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') next = (index - 1 + tabs.length) % tabs.length;
      else if (event.key === 'Home') next = 0;
      else if (event.key === 'End') next = tabs.length - 1;
      else return;
      event.preventDefault();
      showChapter(tabs[next].dataset.chapterTab!, true);
    });
  });
  start.addEventListener('click', () => {
    reset();
    resetButton.disabled = false;
    if (motion.matches) { complete(); return; }
    start.disabled = true;
    label.textContent = 'Playing…';
    setPhase('running', 'Downloading across eight ranges.');
    const schedule = (delay: number, callback: () => void) => {
      timers.push(window.setTimeout(callback, delay));
    };
    schedule(1150, () => setPhase('paused', 'Paused. Each range keeps its place.'));
    schedule(2100, () => setPhase('restoring', 'Relaunching. Reading saved progress.'));
    schedule(2900, () => setPhase('resuming', 'Back to work, from the saved positions.'));
    schedule(4050, complete);
  });
  resetButton.addEventListener('click', reset);
  motion.addEventListener('change', () => {
    if (motion.matches && start.disabled) complete();
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) reset();
  });
  window.addEventListener('pagehide', clearTimers);
  root.dataset.theatreReady = 'true';
  showChapter('transfer');
});
