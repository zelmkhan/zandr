<script lang="ts">
  // Strength meter for a new password: four segments filling up, red while it's weak.
  import { PASSWORD_MIN_LENGTH } from '@/lib/messages';
  import { STRENGTH_LABELS, passwordStrength } from '@/lib/password';

  let { password }: { password: string } = $props();

  const strength = $derived(passwordStrength(password));
</script>

<span class="meter" class:weak={strength === 1} aria-hidden="true">
  {#each [1, 2, 3, 4] as segment}
    <span class:on={strength >= segment}></span>
  {/each}
</span>
<span class="strength" aria-live="polite">
  {password ? STRENGTH_LABELS[strength] : `At least ${PASSWORD_MIN_LENGTH} characters`}
</span>

<style>
  .meter {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 4px;
    margin-top: 2px;
  }

  .meter span {
    height: 3px;
    border-radius: 2px;
    background: rgba(var(--ink), 0.1);
    transition: background-color 0.25s var(--ease);
  }

  .meter span.on {
    background: var(--fg);
  }

  .meter.weak span.on {
    background: var(--danger);
  }

  .strength {
    margin-top: -2px;
    color: var(--muted);
    font-size: 12px;
  }
</style>
