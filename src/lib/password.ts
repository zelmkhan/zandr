import { PASSWORD_MIN_LENGTH } from '@/lib/messages';

// Advisory strength from 0 (too short to use) to 4: length matters most, then mixing kinds of
// characters. Shared by every form that sets a password.
export function passwordStrength(password: string): number {
  if (password.length < PASSWORD_MIN_LENGTH) return 0;
  const kinds = [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].filter((kind) => kind.test(password)).length;
  return 1 + Number(password.length >= 12) + Number(kinds >= 3) + Number(password.length >= 16);
}

export const STRENGTH_LABELS = ['Too short', 'Weak', 'Fair', 'Good', 'Strong'];
