# Zandr website

Static site for the Zandr wallet, built with [Astro](https://astro.build).

## Commands

Run from this directory:

```sh
npm ci            # install exactly what package-lock.json specifies
npm run dev       # dev server at http://localhost:4321
npm run build     # static build to dist/
npm run preview   # serve dist/ locally (use this to test the CSP)
```

## Deploy

Hosted on Railway: project **Zandr**, service **website**, environment **production**. Railway builds it
with Railpack (`npm ci`, `npm run build`) and serves `dist/` with Caddy. To deploy what's in this
directory (files in `.gitignore` aren't uploaded):

```sh
railway link -p Zandr -e production -s website   # once per checkout
railway up --service website --ci                # build and deploy, streaming the build log
```

Public address: https://website-production-30e0.up.railway.app

## Structure

```
src/
  pages/        one .astro file per route (index.astro → /, install.astro → /install)
  components/   reusable pieces: the Install extension button, the name in the top left corner
  layouts/      shared page shell: <head>, fonts, global styles
  styles/       global CSS, same palette and font as the extension
  data/         release.json: the downloadable build's version, size and SHA-256
public/         copied as-is (favicons, the mark in the header, download/ with the extension's zip)
```

## Releasing a build for download

Until zandr is in the stores, `/install` offers the Chrome build as a zip to load by hand. To put a
new build there, run this in the extension's folder (the repo root), then deploy the website:

```sh
npm run release:site   # builds the extension, zips it to public/download/, writes src/data/release.json
```

## Security

- Pages are static HTML; no JavaScript ships unless a page explicitly adds it.
- `security.csp` in `astro.config.mjs` adds a strict Content-Security-Policy to every page.
- Fonts are bundled locally; the site makes no third-party requests.
- `.npmrc` blocks package install scripts and pins exact versions, same as the extension.
