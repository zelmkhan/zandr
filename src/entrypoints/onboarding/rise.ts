import { quintOut } from 'svelte/easing';

// The website's entrance: content rises into place out of a soft blur.
export function rise(_node: Element) {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

  return {
    duration: reduced ? 0 : 600,
    easing: quintOut,
    css: (t: number, u: number) => `opacity: ${t}; transform: translateY(${u * 16}px); filter: blur(${u * 6}px);`,
  };
}
