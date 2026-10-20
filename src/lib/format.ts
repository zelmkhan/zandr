// Shortened as xxxx...xxxxxx, the way addresses are shown in the wallet.
export function shortAddress(address: string): string {
  return `${address.slice(0, 4)}...${address.slice(-6)}`;
}

// Two letters for a wallet's or an address's avatar: the first letters of the name's first two
// words, or the first two of a one-word name; without a name, the address's first two characters,
// as they are.
export function monogram(name: string | null | undefined, address: string): string {
  const words = (name ?? '').trim().split(/\s+/).filter(Boolean);
  if (!words.length) return [...address].slice(0, 2).join('');
  const letters = words.length > 1 ? [[...words[0]!][0], [...words[1]!][0]] : [...words[0]!].slice(0, 2);
  return letters.join('').toUpperCase();
}

const usd = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });
const compact = new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 2 });
const amounts = [2, 4, 6].map((digits) => new Intl.NumberFormat('en-US', { maximumFractionDigits: digits }));
const change = new Intl.NumberFormat('en-US', { style: 'percent', minimumFractionDigits: 2, maximumFractionDigits: 2, signDisplay: 'exceptZero' });

// US dollars, cents included; a sliver under a cent shows as such rather than as $0.00.
export function formatUsd(value: number): string {
  return value > 0 && value < 0.01 ? '<$0.01' : usd.format(value);
}

// A token amount (a decimal string) with as many decimals as are worth reading: fewer for large
// amounts, more for small ones, and billions shortened (1.5B).
export function formatAmount(balance: string): string {
  const amount = Number(balance);
  if (amount === 0) return '0';
  if (amount < 0.000001) return '<0.000001';
  if (amount >= 1e9) return compact.format(amount);
  return amounts[amount >= 1000 ? 0 : amount >= 1 ? 1 : 2]!.format(amount);
}

// A wrong password, and, with erasing after wrong passwords on, how many more may be tried, or
// that this was the last.
export function wrongPassword({ attemptsLeft, erased }: { attemptsLeft: number | null; erased: boolean }, message = 'Wrong password'): string {
  if (erased) return 'Too many wrong passwords: zandr erased every wallet on this device.';
  if (attemptsLeft === null) return `${message}.`;
  return `${message}. ${attemptsLeft} more ${attemptsLeft === 1 ? 'try' : 'tries'} before zandr erases its wallets.`;
}

// A price change in percent, signed: +2.31%, -0.96%.
export function formatChange(percent: number): string {
  return change.format(percent / 100);
}
