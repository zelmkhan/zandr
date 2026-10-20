// @ts-check
import { defineConfig } from 'astro/config';

// https://astro.build/config
export default defineConfig({
  security: {
    // Emits a strict Content-Security-Policy <meta> on every page, with hashes for
    // Astro's own scripts and styles. Not active in `astro dev`; check with build + preview.
    csp: {
      directives: ["default-src 'self'", "object-src 'none'", "base-uri 'none'"],
    },
  },
});
