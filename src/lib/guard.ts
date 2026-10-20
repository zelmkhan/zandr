// Erasing zandr after too many wrong passwords: an optional guard against someone guessing the
// password on this device. Background only.
//
// Every wrong password counts, wherever zandr asks for it (unlocking, showing a private key,
// removing a wallet, changing the password, this very setting), so guessing can't move to a
// place that doesn't count. The count is kept on disk: restarting the browser doesn't reset it.
// A right password does. The setting itself only changes with the password, so whoever is
// guessing can't switch it off first.
//
// It guards against guessing through zandr only. Someone who copies the browser profile can
// guess against the vault elsewhere; scrypt is what slows that down.
import type { WrongPassword } from '@/lib/messages';

// Counted one at a time: wrong passwords tried at once must each count.
let queue: Promise<unknown> = Promise.resolve();

function inTurn<T>(task: () => Promise<T>): Promise<T> {
  const run = queue.then(task);
  queue = run.catch(() => {});
  return run;
}

async function read(): Promise<{ eraseAfter: number | null; failures: number }> {
  const { eraseAfter, failedPasswords } = await browser.storage.local.get(['eraseAfter', 'failedPasswords']);
  return {
    eraseAfter: typeof eraseAfter === 'number' ? eraseAfter : null,
    failures: typeof failedPasswords === 'number' ? failedPasswords : 0,
  };
}

// After a wrong password: how many more may be tried before zandr erases itself (null with the
// guard off), or whether that one was the last and it's done.
export async function wrongPassword(): Promise<WrongPassword> {
  const { eraseAfter, failures } = await read();
  const { vault } = await browser.storage.local.get('vault');
  return { attemptsLeft: eraseAfter === null ? null : Math.max(eraseAfter - failures, 0), erased: vault === undefined };
}

export async function eraseAfter(): Promise<number | null> {
  return (await read()).eraseAfter;
}

export function setEraseAfter(count: number | null): Promise<void> {
  return inTurn(async () => {
    if (count === null) await browser.storage.local.remove(['eraseAfter', 'failedPasswords']);
    else await browser.storage.local.set({ eraseAfter: count, failedPasswords: 0 });
  });
}

export function passwordAccepted(): Promise<void> {
  return inTurn(() => browser.storage.local.remove('failedPasswords'));
}

// Counts a wrong password and, if that was the last one allowed, erases everything.
export function passwordRejected(): Promise<void> {
  return inTurn(async () => {
    const { eraseAfter: limit, failures } = await read();
    if (limit !== null && failures + 1 >= limit) await eraseEverything();
    else await browser.storage.local.set({ failedPasswords: failures + 1 });
  });
}

// Every wallet, key, saved address, setting and cached balance on this device, gone. What's
// left is a note that it happened, so zandr can say why the wallets are missing.
async function eraseEverything() {
  await browser.storage.session.clear();
  await browser.storage.local.clear();
  await browser.alarms.clearAll();
  await browser.storage.local.set({ erasedAt: Date.now() });
}

export async function wasErased(): Promise<boolean> {
  const { erasedAt } = await browser.storage.local.get('erasedAt');
  return typeof erasedAt === 'number';
}
