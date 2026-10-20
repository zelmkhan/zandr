// Why loading the wallet's coins or history failed, said for the user, in two sizes: a title and
// a line for an empty screen, or one short sentence for a notice.
import type { PortfolioEntry } from '@/lib/messages';

export type Problem = NonNullable<PortfolioEntry['problem']>;

// `settings`: setting up another RPC endpoint may fix it.
export function describeProblem(problem: Problem, what: string): { title: string; text: string; settings: boolean } {
  if (problem.service === 'tokens') return { title: "Couldn't load prices", text: 'zandr will try again shortly.', settings: false };
  switch (problem.reason) {
    case 'forbidden':
      return {
        title: 'The RPC endpoint refused',
        text: "It doesn't serve browser extensions, or it needs an API key. Set up an endpoint in Network settings.",
        settings: true,
      };
    case 'rate-limited':
      return { title: 'The RPC endpoint is busy', text: "It's limiting requests. zandr will try again shortly.", settings: false };
    case 'unreachable':
      return { title: "Couldn't reach the network", text: 'Check your connection. zandr will try again shortly.', settings: false };
    default:
      return { title: `Couldn't load your ${what}`, text: 'The RPC endpoint gave an unexpected answer.', settings: true };
  }
}

export function problemReason(problem: Problem): string {
  if (problem.service === 'tokens') return "Prices didn't load.";
  switch (problem.reason) {
    case 'forbidden':
      return 'The RPC endpoint refused: set one up in Network settings.';
    case 'rate-limited':
      return 'The RPC endpoint is busy.';
    case 'unreachable':
      return "The network can't be reached.";
    default:
      return 'The RPC endpoint gave an unexpected answer.';
  }
}
