import { mount } from 'svelte';
import App from './App.svelte';
import '@fontsource-variable/geist/wght.css';
import '@/assets/theme.css';
import './view.css';
import './screen.css';
import './flow.css';
import { applyTheme } from '@/lib/theme';

// Where the wallet view is shown: the toolbar popup, or Chrome's side panel.
export type View = 'popup' | 'sidepanel';

// Fonts load lazily on first use, so the first typed character would briefly render
// with fallback (smaller) password dots. Load them up front; they're bundled, so it's fast.
const fonts = ['500 16px "Geist Variable"', '28px "Geist Password"', '28px "Geist Password Empty"'];

export function mountWallet(view: View) {
  applyTheme();
  Promise.all(fonts.map((font) => document.fonts.load(font))).finally(() => {
    mount(App, { target: document.getElementById('app')!, props: { view } });
  });
}
