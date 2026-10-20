// Puts the Chrome build on the website for download, for installing by hand ("Load unpacked")
// until zandr is in the stores. The built extension (.output/chrome-mv3, from `wxt build`) is
// zipped inside a single `zandr` folder: unzipped, that's the folder Chrome loads, and the one an
// update replaces in place, so the extension keeps its ID and its data. The zip goes to
// website/public/download/ (older ones there are removed), and what the install page shows about
// it (version, size, SHA-256) to website/src/data/release.json.
// Run with `npm run release:site`, then deploy the website.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const build = join(root, '.output/chrome-mv3');
const downloads = join(root, 'website/public/download');
const data = join(root, 'website/src/data');

// version_name carries what the bare version can't, like "0.0.1-beta".
const manifest = JSON.parse(readFileSync(join(build, 'manifest.json'), 'utf8'));
const version = manifest.version_name ?? manifest.version;
const file = `zandr-${version}-chrome.zip`;

const staging = mkdtempSync(join(tmpdir(), 'zandr-release-'));
try {
  cpSync(build, join(staging, 'zandr'), { recursive: true });
  // -X: no extra file attributes (macOS metadata and the like).
  execFileSync('zip', ['-r', '-X', '-q', join(staging, file), 'zandr'], { cwd: staging });

  mkdirSync(downloads, { recursive: true });
  for (const old of readdirSync(downloads)) if (old.endsWith('.zip')) rmSync(join(downloads, old));
  cpSync(join(staging, file), join(downloads, file));
} finally {
  rmSync(staging, { recursive: true, force: true });
}

const bytes = readFileSync(join(downloads, file));
const release = {
  version,
  file,
  bytes: bytes.length,
  sha256: createHash('sha256').update(bytes).digest('hex'),
  date: new Date().toISOString().slice(0, 10),
};
mkdirSync(data, { recursive: true });
writeFileSync(join(data, 'release.json'), `${JSON.stringify(release, null, 2)}\n`);
console.log(`website/public/download/${file}  ${(bytes.length / 1024).toFixed(0)} KB  sha256 ${release.sha256}`);
