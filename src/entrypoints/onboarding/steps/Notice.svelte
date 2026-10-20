<script lang="ts">
  let { onnext }: { onnext: () => Promise<void> } = $props();

  let understood = $state(false);
  let busy = $state(false);
  let failed = $state(false);

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    busy = true;
    failed = false;
    try {
      await onnext();
    } catch {
      failed = true;
    } finally {
      busy = false;
    }
  }
</script>

<form onsubmit={submit}>
  <h1 class="title">You're in full control</h1>
  <p class="lead">zandr is a self-custody wallet. A 12-word recovery phrase controls your funds, and only you will have it.</p>

  <ul class="points">
    <li>
      <span class="icon">
        <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
          <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
            <path d="m15.5 7.5 2.3 2.3a1 1 0 0 0 1.4 0l2.1-2.1a1 1 0 0 0 0-1.4L19 4m2-2-9.6 9.6" />
            <circle cx="7.5" cy="15.5" r="5.5" />
          </g>
        </svg>
      </span>
      <div>
        <strong>Only you hold it</strong>
        <span>It never leaves this device, and we never see it.</span>
      </div>
    </li>
    <li class="danger">
      <span class="icon">
        <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
          <path
            d="M10.3 4.2 2.6 17.5A2 2 0 0 0 4.3 20.5h15.4a2 2 0 0 0 1.7-3L13.7 4.2a2 2 0 0 0-3.4 0ZM12 9.5v4m0 3.5h.01"
            fill="none"
            stroke="currentColor"
            stroke-width="1.75"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </span>
      <div>
        <strong>Lose it, and your wallet can't be recovered</strong>
        <span>Not by you, not by zandr, not by anyone.</span>
      </div>
    </li>
    <li>
      <span class="icon">
        <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
          <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
            <path d="M10.7 5.1A10.4 10.4 0 0 1 12 5c6.4 0 10 7 10 7a17.6 17.6 0 0 1-2.1 3" />
            <path d="M6.6 6.6C3.7 8.4 2 12 2 12s3.6 7 10 7a9.8 9.8 0 0 0 5.4-1.6" />
            <path d="M9.9 9.9a3 3 0 0 0 4.2 4.2" />
            <path d="m2 2 20 20" />
          </g>
        </svg>
      </span>
      <div>
        <strong>Never share it</strong>
        <span>Anyone with your phrase can take your funds. zandr will never ask for it.</span>
      </div>
    </li>
  </ul>

  <label class="check">
    <input type="checkbox" bind:checked={understood} />
    <span>I understand that if I lose my recovery phrase, I lose access to my wallet for good.</span>
  </label>

  <button class="button" disabled={!understood || busy}>Continue</button>
  {#if failed}
    <p class="error" role="alert">Couldn't generate a recovery phrase. Please try again.</p>
  {/if}
</form>

<style>
  .points {
    display: flex;
    flex-direction: column;
    gap: 20px;
    margin: 28px 0 0;
    padding: 0;
    list-style: none;
  }

  li {
    display: flex;
    gap: 14px;
  }

  .icon {
    display: grid;
    flex: none;
    place-items: center;
    width: 36px;
    height: 36px;
    border-radius: 50%;
    background: var(--fill);
  }

  .danger .icon {
    background: rgba(240, 140, 126, 0.12);
    color: var(--danger);
  }

  div {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding-top: 1px;
  }

  strong {
    font-size: 15px;
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  div span {
    color: var(--muted);
    font-size: 14px;
    line-height: 1.45;
  }
</style>
