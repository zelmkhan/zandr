// Keeps src/server movable to a real server: its files may import only each other (by relative
// path, with the .ts extension, so Node and other runtimes can load them as they are, or a .json
// file of data beside them) and must not touch the extension APIs.
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../src/server');
const problems = [];

for (const name of readdirSync(root, { recursive: true })) {
  if (!name.endsWith('.ts')) continue;
  const file = join(root, name);
  const source = readFileSync(file, 'utf8');
  const where = relative(process.cwd(), file);

  for (const [, specifier] of source.matchAll(/(?:import|export)\s[^'"]*?from\s+['"]([^'"]+)['"]/g)) {
    const target = resolve(dirname(file), specifier);
    if (!specifier.startsWith('.') || !/\.(ts|json)$/.test(specifier) || relative(root, target).startsWith('..')) {
      problems.push(`${where}: imports "${specifier}"; only ./*.ts and ./*.json files inside src/server are allowed`);
    }
  }
  if (/\b(browser|chrome)\.\w/.test(source)) problems.push(`${where}: uses an extension API`);
}

if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
console.log('src/server is self-contained');
