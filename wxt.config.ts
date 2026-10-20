import { defineConfig } from 'wxt';

// See https://wxt.dev/api/config.html
export default defineConfig({
  srcDir: 'src',
  modules: ['@wxt-dev/module-svelte'],
  manifest: ({ browser }) => ({
    name: 'Zandr',
    description:
      'A Solana wallet designed to protect your funds from threats and from simple human error.',
    // Add permissions only when a feature actually needs them: each one widens
    // the attack surface and triggers extra Chrome Web Store review.
    // storage: the encrypted vault (local) and the unlocked session (session).
    // alarms: auto-lock wipes the session on time even when nothing else wakes the background.
    // offscreen: a hidden page that sees the browser's light or dark theme, for the toolbar icon.
    // favicon (Chrome only): sites' icons from the browser's own favicon cache, for the approval
    // window and connected apps, so zandr never fetches them from the sites. Chrome lists it at
    // install as "Read the icons of the websites you visit"; the others show no warning.
    permissions: ['storage', 'alarms', 'offscreen', ...(browser === 'chrome' ? ['favicon'] : [])],
    content_security_policy: {
      // Stricter than the MV3 default: no WASM, no plugins, no <base>, no framing.
      // If a crypto library needs WASM later, add 'wasm-unsafe-eval' to script-src.
      extension_pages:
        "script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none';",
    },
  }),
});
