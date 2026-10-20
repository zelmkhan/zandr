<script lang="ts">
  // Saved addresses, inside the wallet view. They're encrypted and authenticated by the
  // background (lib/vault.ts); this screen only lists, adds and removes them.
  import { onMount } from 'svelte';
  import { scale } from 'svelte/transition';
  import { monogram, shortAddress } from '@/lib/format';
  import { CONTACT_NAME_MAX_LENGTH, sendToBackground, type Contact, type ContactError } from '@/lib/messages';

  let { onback }: { onback: () => void } = $props();

  type Book = { kind: 'loading' } | { kind: 'ready'; contacts: Contact[] } | { kind: 'tampered' } | { kind: 'failed' };
  let book = $state<Book>({ kind: 'loading' });

  async function load() {
    try {
      const result = await sendToBackground({ type: 'addressBook:list' });
      if ('contacts' in result) book = { kind: 'ready', contacts: result.contacts };
      else book = { kind: result.error === 'tampered' ? 'tampered' : 'failed' };
    } catch {
      book = { kind: 'failed' };
    }
  }

  onMount(load);

  // Adding an address.
  let adding = $state(false);
  let name = $state('');
  let address = $state('');
  let error = $state<{ field: 'name' | 'address'; message: string } | null>(null);
  let saving = $state(false);

  const trimmed = $derived(address.trim());
  // The address in groups of four, to check against its source before saving.
  const groups = $derived(trimmed.length >= 32 && trimmed.length <= 44 ? (trimmed.match(/.{1,4}/g) ?? []) : []);

  const reasons: Record<ContactError, (conflict?: string) => string> = {
    name: () => `Give it a name of up to ${CONTACT_NAME_MAX_LENGTH} characters.`,
    'invalid-address': () => "This isn't a valid Solana address.",
    'own-address': () => "This is your own wallet's address.",
    duplicate: (conflict) => `Already saved as “${conflict}”.`,
    lookalike: (conflict) =>
      `This looks almost the same as “${conflict}” but is a different address. Lookalike addresses are a common scam: check where you copied it from.`,
  };

  function startAdding() {
    adding = true;
    name = '';
    address = '';
    error = null;
  }

  async function save(event: SubmitEvent) {
    event.preventDefault();
    saving = true;
    error = null;
    try {
      const result = await sendToBackground({ type: 'addressBook:add', name, address });
      if (result.ok) {
        adding = false;
        await load();
      } else {
        error = { field: result.error === 'name' ? 'name' : 'address', message: reasons[result.error](result.conflict) };
      }
    } catch {
      error = { field: 'address', message: "Couldn't save the address. Please try again." };
    } finally {
      saving = false;
    }
  }

  // Deleting takes a second click on the same row.
  let confirming = $state<string | null>(null);

  async function remove(id: string) {
    if (confirming !== id) {
      confirming = id;
      return;
    }
    confirming = null;
    await sendToBackground({ type: 'addressBook:remove', id });
    await load();
  }

  let copied = $state<string | null>(null);
  let copiedTimer: ReturnType<typeof setTimeout> | undefined;

  async function copy(contact: Contact) {
    try {
      await navigator.clipboard.writeText(contact.address);
    } catch {
      return;
    }
    copied = contact.id;
    clearTimeout(copiedTimer);
    copiedTimer = setTimeout(() => (copied = null), 1500);
  }

  async function clear() {
    await sendToBackground({ type: 'addressBook:clear' });
    await load();
  }
</script>

<div class="screen">
  <div class="bar">
    <button type="button" class="icon-button" aria-label="Back" onclick={() => (adding ? (adding = false) : onback())}>
      <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M19 12H5m6-6-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
    <h2>{adding ? 'Add address' : 'Address book'}</h2>
    {#if !adding && book.kind === 'ready' && book.contacts.length}
      <button type="button" class="icon-button" aria-label="Add address" onclick={startAdding}>
        <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
          <path d="M12 5v14M5 12h14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
        </svg>
      </button>
    {:else}
      <span class="spacer"></span>
    {/if}
  </div>

  {#if adding}
    <form class="form" onsubmit={save}>
      <label class="field">
        <span>Name</span>
        <input
          bind:value={name}
          oninput={() => (error = null)}
          maxlength={CONTACT_NAME_MAX_LENGTH}
          placeholder="e.g. Binance deposit"
          aria-invalid={error?.field === 'name' ? 'true' : undefined}
          autocomplete="off"
          spellcheck="false"
        />
      </label>

      <label class="field">
        <span>Solana address</span>
        <textarea
          bind:value={address}
          oninput={() => (error = null)}
          rows="2"
          placeholder="Paste or type the address"
          aria-invalid={error?.field === 'address' ? 'true' : undefined}
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
        ></textarea>
      </label>

      <!-- A copied address can be swapped on the way in by malware: check it before it's trusted. -->
      {#if groups.length}
        <div class="verify">
          <p>Check every character against where you copied it from. Malware can swap a copied address.</p>
          <code>
            {#each groups as group}
              <span>{group}</span>
            {/each}
          </code>
        </div>
      {/if}

      {#if error}
        <p class="error" role="alert">{error.message}</p>
      {/if}

      <button type="submit" class="primary" disabled={!name.trim() || !trimmed || saving}>
        {saving ? 'Saving…' : 'Save address'}
      </button>
    </form>
  {:else if book.kind === 'tampered'}
    <div class="notice" role="alert">
      <strong>Your address book couldn't be verified</strong>
      <p>
        It was changed outside zandr, so zandr won't use any of it. Clear it and add your addresses again from sources
        you trust.
      </p>
      <button type="button" class="primary" onclick={clear}>Clear address book</button>
    </div>
  {:else if book.kind === 'failed'}
    <p class="empty-text">Couldn't load your address book.</p>
  {:else if book.kind === 'ready' && book.contacts.length === 0}
    <div class="empty">
      <span class="empty-icon">
        <svg width="22" height="22" viewBox="0 0 24 24" aria-hidden="true">
          <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
            <path d="M5 4.5A2.5 2.5 0 0 1 7.5 2H19v20H7.5A2.5 2.5 0 0 1 5 19.5v-15Z" />
            <path d="M5 19.5A2.5 2.5 0 0 1 7.5 17H19" />
            <circle cx="12" cy="9" r="2.5" />
          </g>
        </svg>
      </span>
      <strong>No saved addresses</strong>
      <p>Save the addresses you send to, so you never have to paste them again.</p>
      <button type="button" class="primary" onclick={startAdding}>Add address</button>
    </div>
  {:else if book.kind === 'ready'}
    <ul class="list">
      {#each book.contacts as contact (contact.id)}
        <li>
          <span class="initial" aria-hidden="true">{monogram(contact.name, contact.address)}</span>
          <div class="who">
            <strong>{contact.name}</strong>
            <span title={contact.address}>{shortAddress(contact.address)}</span>
          </div>
          {#if confirming === contact.id}
            <button type="button" class="delete" onclick={() => remove(contact.id)}>Delete</button>
            <button type="button" class="icon-button small" aria-label="Keep it" onclick={() => (confirming = null)}>
              <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
                <path d="M6 6l12 12M18 6 6 18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
              </svg>
            </button>
          {:else}
            <button type="button" class="icon-button small" aria-label="Copy {contact.name}'s address" onclick={() => copy(contact)}>
              {#key copied === contact.id}
                <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true" in:scale={{ duration: 200, start: 0.5 }}>
                  <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    {#if copied === contact.id}
                      <path d="M5 12.5 9.5 17 19 7.5" />
                    {:else}
                      <rect x="8" y="8" width="13" height="13" rx="2.5" />
                      <path d="M16 8V5.5A2.5 2.5 0 0 0 13.5 3h-8A2.5 2.5 0 0 0 3 5.5v8A2.5 2.5 0 0 0 5.5 16H8" />
                    {/if}
                  </g>
                </svg>
              {/key}
            </button>
            <button type="button" class="icon-button small" aria-label="Delete {contact.name}" onclick={() => remove(contact.id)}>
              <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
                <path
                  d="M4 7h16m-10 4v6m4-6v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.75"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
              </svg>
            </button>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</div>

<style>
  .delete {
    height: 30px;
    padding: 0 12px;
    border: 0;
    border-radius: 999px;
    background: rgba(240, 140, 126, 0.15);
    color: var(--danger);
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
  }

  /* Empty and problem states. */
  .empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    margin: auto 0;
    padding: 24px 8px;
    text-align: center;
  }

  .empty-icon {
    display: grid;
    place-items: center;
    width: 52px;
    height: 52px;
    margin-bottom: 14px;
    border-radius: 50%;
    background: var(--fill);
  }

  .empty strong,
  .notice strong {
    font-size: 15px;
    font-weight: 600;
  }

  .empty p,
  .notice p {
    margin: 6px 0 18px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .empty .primary {
    padding: 0 22px;
  }

  .empty-text {
    margin: auto;
    color: var(--muted);
  }

  .notice {
    display: flex;
    flex-direction: column;
    margin-top: 8px;
    padding: 16px;
    border-radius: 14px;
    background: rgba(240, 140, 126, 0.08);
  }

  .notice strong {
    color: var(--danger);
  }

  .verify {
    padding: 12px;
    border-radius: 10px;
    background: var(--fill);
  }

  .verify p {
    margin: 0 0 8px;
    color: var(--muted);
    font-size: 12px;
    line-height: 1.45;
  }

  /* In one piece: groups of four told apart by tone, not by gaps that would read as spaces. */
  .verify code {
    display: block;
    font-family: inherit;
    font-size: 14px;
    font-weight: 500;
    letter-spacing: 0.02em;
  }

  .verify code span {
    display: inline-block;
  }

  .verify code span:nth-child(even) {
    opacity: 0.5;
  }
</style>
