// The window zandr opens when a site asks for something: connecting, or signing.
import { mount } from 'svelte';
import App from './App.svelte';
import '@fontsource-variable/geist/wght.css';
import '@/assets/theme.css';
import '../popup/view.css';
import '../popup/screen.css';
import '../popup/flow.css';
import './app.css';
import { applyTheme } from '@/lib/theme';

// As in the wallet: the password field's fonts up front, so its first dots aren't fallback ones.
const fonts = ['500 16px "Geist Variable"', '28px "Geist Password"', '28px "Geist Password Empty"'];

applyTheme();

Promise.all(fonts.map((font) => document.fonts.load(font))).finally(() => {
  mount(App, { target: document.getElementById('app')! });
});
