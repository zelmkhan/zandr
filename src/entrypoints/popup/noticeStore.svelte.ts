// Warnings and errors for the wallet view, shown in an orange block at the bottom until closed or
// no longer true. Each has a key: telling it again updates it rather than adding another, and once
// closed it stays away until its problem clears (`clear`) and comes back.
export type Notice = { key: string; title: string; text: string };

const MAX_SHOWN = 3;

let shown = $state<Notice[]>([]);
const closed = new Set<string>();

export function notices(): Notice[] {
  return shown;
}

export function notify(key: string, title: string, text: string) {
  if (closed.has(key)) return;
  const existing = shown.find((notice) => notice.key === key);
  if (existing) {
    if (existing.title !== title || existing.text !== text) shown = shown.map((notice) => (notice.key === key ? { key, title, text } : notice));
    return;
  }
  shown = [...shown, { key, title, text }].slice(-MAX_SHOWN);
}

// Closed by the user: not shown again while the problem lasts.
export function close(key: string) {
  closed.add(key);
  shown = shown.filter((notice) => notice.key !== key);
}

// The problem is over: gone, and free to show again next time.
export function clear(key: string) {
  closed.delete(key);
  if (shown.some((notice) => notice.key === key)) shown = shown.filter((notice) => notice.key !== key);
}
