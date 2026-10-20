// Amounts in whole coins (decimal strings, as people read and type them) and in a token's
// smallest unit (bigint, as the chain counts), converted exactly.

// "1.5" with 6 decimals is 1500000n. Null for anything but a plain decimal with at most that
// many decimals.
export function parseUnits(text: string, decimals: number): bigint | null {
  const match = /^(\d*)(?:\.(\d*))?$/.exec(text.trim());
  if (!match || !(match[1] || match[2])) return null;
  const [, whole = '', fraction = ''] = match;
  if (fraction.length > decimals) return null;
  return BigInt((whole || '0') + fraction.padEnd(decimals, '0'));
}

// 1500000n with 6 decimals is "1.5".
export function formatUnits(amount: bigint, decimals: number): string {
  const digits = amount.toString().padStart(decimals + 1, '0');
  const whole = digits.slice(0, digits.length - decimals);
  const fraction = digits.slice(digits.length - decimals).replace(/0+$/, '');
  return fraction ? `${whole}.${fraction}` : whole;
}
