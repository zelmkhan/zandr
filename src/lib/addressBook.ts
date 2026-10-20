// The address book's rules: what may be saved, and why not. Background only: never import this
// from a page. Storage and encryption live in vault.ts.
import { base58 } from '@scure/base';
import { CONTACT_NAME_MAX_LENGTH, type Contact, type ContactError } from '@/lib/messages';
import { LockedError, getSession, updateAddressBook } from '@/lib/vault';

export type AddResult = { ok: true; contact: Contact } | { ok: false; error: ContactError; conflict?: string };

function isAddress(value: string): boolean {
  try {
    return base58.decode(value).length === 32;
  } catch {
    return false;
  }
}

// Same first and last four characters, the part shortened displays show, but a different
// address: the shape of address poisoning, where a scammer's lookalike lands in your history.
export function lookalike(a: string, b: string): boolean {
  return a !== b && a.slice(0, 4) === b.slice(0, 4) && a.slice(-4) === b.slice(-4);
}

export async function addContact(nameInput: string, addressInput: string): Promise<AddResult> {
  const name = nameInput.trim();
  const address = addressInput.trim();
  if (!name || name.length > CONTACT_NAME_MAX_LENGTH) return { ok: false, error: 'name' };
  if (!isAddress(address)) return { ok: false, error: 'invalid-address' };

  const account = await getSession();
  if (!account) throw new LockedError();
  if (address === account.address) return { ok: false, error: 'own-address' };
  if (lookalike(address, account.address)) return { ok: false, error: 'lookalike', conflict: account.name };

  let result: AddResult = { ok: false, error: 'invalid-address' };
  await updateAddressBook((contacts) => {
    const same = contacts.find((contact) => contact.address === address);
    if (same) {
      result = { ok: false, error: 'duplicate', conflict: same.name };
      return contacts;
    }
    const similar = contacts.find((contact) => lookalike(contact.address, address));
    if (similar) {
      result = { ok: false, error: 'lookalike', conflict: similar.name };
      return contacts;
    }

    const contact: Contact = { id: crypto.randomUUID(), name, address, addedAt: Date.now() };
    result = { ok: true, contact };
    return [...contacts, contact];
  });
  return result;
}

export async function removeContact(id: string): Promise<void> {
  await updateAddressBook((contacts) => contacts.filter((contact) => contact.id !== id));
}
