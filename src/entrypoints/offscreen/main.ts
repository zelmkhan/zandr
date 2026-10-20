// A hidden page that tells the background whether the browser is in a light or a dark theme, now
// and whenever it changes: the toolbar icon follows it, and a service worker has no matchMedia.
import { sendToBackground } from '@/lib/messages';

const dark = matchMedia('(prefers-color-scheme: dark)');
let reported: boolean | null = null;

function report() {
  if (dark.matches === reported) return;
  reported = dark.matches;
  sendToBackground({ type: 'theme:set', dark: reported }).catch(() => (reported = null));
}

// A page that's never drawn never gets the media query's change event, but `matches` is always
// current: read it every second (cheap), and on the event too, should Chrome send it.
report();
dark.addEventListener('change', report);
setInterval(report, 1000);
