<script lang="ts">
  // The wallet's DeFi positions, next to its coins: staking, lending, liquidity.
  // TODO: the positions, read from the network.
</script>

<div class="defi">
  <div class="center">
    <span class="center-icon">
      <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
        <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
          <path d="m12 3 9 5-9 5-9-5 9-5Z" />
          <path d="m3 13 9 5 9-5" />
        </g>
      </svg>
    </span>
    <p class="center-title">No DeFi positions yet</p>
    <p class="center-text">Staking, lending and liquidity positions will show up here.</p>
  </div>
</div>

<style>
  .defi {
    flex: 1;
    display: flex;
    flex-direction: column;
  }

  /* As the coins' empty state: centered in the space left below the tabs. */
  .center {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 24px 24px 0;
    text-align: center;
  }

  .center-icon {
    display: grid;
    place-items: center;
    width: 48px;
    height: 48px;
    margin-bottom: 14px;
    border-radius: 50%;
    background: var(--fill);
    color: var(--muted);
  }

  .center-title {
    margin: 0;
    font-size: 16px;
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  .center-text {
    max-width: 250px;
    margin: 6px 0 0;
    color: var(--muted);
    font-size: 14px;
    line-height: 1.45;
  }
</style>
