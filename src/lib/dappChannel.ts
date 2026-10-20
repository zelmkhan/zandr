// The postMessage channel between zandr's two content scripts on a web page: the wallet the page
// sees (in the page's own world) and the bridge to the background (in zandr's isolated world).
export const CHANNEL = 'zandr:wallet';

// Where sites may connect from: https, and local development servers.
export const MATCHES = ['https://*/*', 'http://localhost/*', 'http://127.0.0.1/*'];

// The site's icon as its page declares it, for zandr's own windows: a large one (an SVG, an Apple
// touch icon, or an icon of 64 pixels or more, from the page's links or else its web app manifest),
// which looks sharp where a favicon wouldn't. The address is the page's own say, so the background
// takes only https ones (http on a local site), or a small inline image, and shows it only as an
// image. Null if there's none worth it.
export async function pageIcon(): Promise<string | null> {
  const icons: Icon[] = [];
  for (const link of document.querySelectorAll<HTMLLinkElement>('link[rel]')) {
    const rel = link.rel.toLowerCase().split(/\s+/);
    const touch = rel.includes('apple-touch-icon') || rel.includes('apple-touch-icon-precomposed');
    if (touch || rel.includes('icon')) icons.push({ src: link.href, sizes: link.getAttribute('sizes'), type: link.type, touch });
  }
  const found = largest(icons);
  if (found) return found;

  // The web app manifest's icons: often the only large ones a site has.
  const manifest = document.querySelector<HTMLLinkElement>('link[rel~="manifest" i]')?.href;
  if (!manifest || new URL(manifest).origin !== location.origin) return null;
  try {
    const response = await fetch(manifest, { credentials: 'same-origin', signal: AbortSignal.timeout(1500) });
    const body = (await response.json()) as { icons?: unknown };
    const listed = Array.isArray(body.icons) ? (body.icons as Record<string, unknown>[]) : [];
    return largest(
      listed.flatMap((icon) =>
        typeof icon?.src === 'string' ? [{ src: new URL(icon.src, manifest).href, sizes: typeof icon.sizes === 'string' ? icon.sizes : null, type: String(icon.type ?? ''), touch: false }] : [],
      ),
    );
  } catch {
    return null;
  }
}

type Icon = { src: string; sizes: string | null; type: string; touch: boolean };

// The largest icon of 64 pixels or more: a vector counts as any size. Without its sizes stated, an
// icon's size is read from its file name (apple-icon-57x57.png), else an Apple touch icon is taken
// for the usual 180.
function largest(icons: Icon[]): string | null {
  let best: { src: string; size: number } | null = null;
  for (const { src, sizes, type, touch } of icons) {
    if (!src) continue;
    const declared = (sizes ?? '').toLowerCase();
    const stated = declared.split(/\s+/).map((size) => parseInt(size, 10)).filter((size) => size > 0);
    const named = /(\d{2,4})x\1(?!\d)/.exec(src);
    const vector = declared.includes('any') || type === 'image/svg+xml' || /\.svg(\?|#|$)/i.test(src);
    const size = vector ? 1024 : stated.length ? Math.max(...stated) : named ? Number(named[1]) : touch ? 180 : 0;
    if (size >= 64 && (!best || size > best.size)) best = { src, size };
  }
  return best?.src ?? null;
}

const INLINE_IMAGE = /^data:image\/(png|jpeg|webp|gif|svg\+xml);base64,[A-Za-z0-9+/=]+$/;

// A page's icon address, as the background takes it: https (http only from a local site), or an
// inline image of up to 150 kB.
export function checkedPageIcon(value: unknown, origin: string): string | null {
  if (typeof value !== 'string') return null;
  if (value.startsWith('data:')) return value.length <= 200_000 && INLINE_IMAGE.test(value) ? value : null;
  if (value.length > 2048) return null;
  try {
    const url = new URL(value);
    const local = new URL(origin).protocol === 'http:';
    return url.protocol === 'https:' || (local && url.protocol === 'http:' && url.origin === origin) ? url.href : null;
  } catch {
    return null;
  }
}
