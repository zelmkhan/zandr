// Puts the chosen theme on <html> (data-theme="dark" or "light") before a page first draws: from
// a copy in localStorage, which reads synchronously, then from the preference itself, and again
// whenever the preference or, for "system", the system's theme changes.
import { DEFAULT_PREFERENCES, loadPreferences, THEME_CHOICES, type Theme } from '@/lib/preferences';

const COPY = 'theme';
const systemLight = matchMedia('(prefers-color-scheme: light)');
let current: Theme = DEFAULT_PREFERENCES.theme;

function apply(theme: Theme) {
  current = theme;
  const light = theme === 'light' || (theme === 'system' && systemLight.matches);
  document.documentElement.dataset.theme = light ? 'light' : 'dark';
}

function copied(): Theme | null {
  try {
    const theme = localStorage.getItem(COPY) as Theme | null;
    return theme && THEME_CHOICES.includes(theme) ? theme : null;
  } catch {
    return null;
  }
}

async function sync() {
  const { theme } = await loadPreferences();
  apply(theme);
  try {
    localStorage.setItem(COPY, theme);
  } catch {
    // Without the copy, the next page shows the default theme for a moment first; nothing worse.
  }
}

export function applyTheme() {
  apply(copied() ?? DEFAULT_PREFERENCES.theme);
  sync();
  systemLight.addEventListener('change', () => apply(current));
  browser.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && 'preferences' in changes) sync();
  });
}
