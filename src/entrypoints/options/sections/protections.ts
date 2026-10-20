import type { ProtectionId } from '@/lib/preferences';

// A page inside Security: one of the protections, changing the password, or erasing after wrong
// passwords.
export type SecurityPage = ProtectionId | 'password' | 'erase';

// What each transfer protection is, for its row in Security and its own page.
export type ProtectionInfo = {
  title: string;
  // One line for the list.
  summary: string;
  // The problem it prevents, at the top of its page.
  lead: string;
  steps: { title: string; text: string }[];
  // What it doesn't catch, so nobody relies on it for more than it does.
  limits: string[];
  // Whether zandr runs it yet. The exchange check runs once it has a current list for an exchange.
  live: boolean;
};

export const PROTECTION_ORDER: ProtectionId[] = [
  'exchangeSupport',
  'programAddresses',
  'mintAddresses',
  'tokenAccounts',
  'lookalikeAddresses',
];

export const PROTECTIONS: Record<ProtectionId, ProtectionInfo> = {
  exchangeSupport: {
    title: 'Unsupported tokens on exchanges',
    summary: "Stop a transfer when the address belongs to an exchange that doesn't accept the token.",
    lead: "Exchanges accept only some tokens on each network. Send one they don't support and it usually never reaches your account, and getting it back, if the exchange can at all, takes weeks.",
    steps: [
      {
        title: 'Recognizes exchange addresses',
        text: "zandr checks whether the address you're sending to is a deposit address of an exchange it knows, or the exchange's own wallet, which credits no one.",
      },
      {
        title: 'Checks the token',
        text: 'It looks up whether that exchange accepts this exact token on Solana, matched by its mint address rather than its name, so look-alike tokens don\'t slip through, and whether the amount reaches the exchange\'s minimum deposit.',
      },
      {
        title: 'Stops the transfer',
        text: "If the exchange doesn't accept it, zandr stops the transfer and tells you why, before anything leaves your wallet.",
      },
    ],
    limits: [
      "A brand-new deposit address that hasn't received anything yet: it can't be told apart from a regular wallet.",
      "A deposit address that sends its deposits on to an exchange wallet zandr doesn't know.",
      "Tokens of exchanges marked Addresses only or Partial above: their token lists aren't public or not complete.",
      "On exchanges marked Traded tokens: a token the exchange trades but takes only on another network.",
      "Changes an exchange makes to its tokens since zandr's last update of its list (every few hours).",
      "A transfer when zandr can't tell within a few seconds whether the address is an exchange's: it isn't held up for it.",
    ],
    live: true,
  },
  programAddresses: {
    title: 'Program addresses',
    summary: 'Stop transfers to programs and to addresses only a program controls, where tokens can get stuck for good.',
    lead: 'Programs, and the addresses they control, have no private key. Tokens sent there can only be moved by the program itself, which usually never happens.',
    steps: [
      {
        title: 'Looks up the recipient',
        text: 'Before sending, zandr checks on-chain whether the address is a program, or an address derived from one, rather than a regular wallet.',
      },
      {
        title: 'Stops the transfer',
        text: "If it is, zandr stops the transfer and explains what the address is.",
      },
    ],
    limits: [
      "Transfers that apps you connect to make as part of their own transactions, like a swap or a deposit into a protocol.",
      'Wallets that are themselves controlled by a program, such as multisig vaults: they are stopped too, and you can send anyway once you have checked.',
    ],
    live: true,
  },
  mintAddresses: {
    title: 'Token mint addresses',
    summary: "Stop transfers to a token's own mint address, a common copy-paste mistake.",
    lead: "A mint address identifies a token itself, much like a contract address. It's easy to copy it from an explorer or a token page by mistake, and tokens sent there are lost.",
    steps: [
      {
        title: 'Looks up the recipient',
        text: 'zandr checks on-chain whether the address is a token mint.',
      },
      {
        title: 'Stops the transfer',
        text: 'If it is, zandr stops the transfer and names the token the address belongs to.',
      },
    ],
    limits: [],
    live: true,
  },
  tokenAccounts: {
    title: 'Token account addresses',
    summary: 'Stop transfers to a token account instead of the wallet that owns it.',
    lead: 'On Solana each token sits in a separate token account that belongs to a wallet. Sending to a token account as if it were a wallet locks the tokens in an account nobody can use.',
    steps: [
      {
        title: 'Looks up the recipient',
        text: 'zandr checks on-chain whether the address is a token account rather than a wallet.',
      },
      {
        title: 'Points you to the owner',
        text: 'If it is, zandr stops the transfer and shows the wallet that owns it, so you can send there instead.',
      },
    ],
    limits: ['Sending a token into a token account for that same token: a valid transfer, so it goes through.'],
    live: true,
  },
  lookalikeAddresses: {
    title: 'Lookalike addresses',
    summary: "Stop transfers to an address that starts and ends like one you know, but isn't it.",
    lead: "Scammers send tiny amounts from addresses that share the first and last characters with ones you use, hoping you'll copy theirs from your history next time. Wallets show addresses shortened, so the two look the same.",
    steps: [
      {
        title: 'Compares the recipient',
        text: 'zandr checks it against your wallets and the addresses in your address book: the same first and last four characters, but a different address in between.',
      },
      {
        title: 'Stops the transfer',
        text: 'If it looks like one of them without being it, zandr stops the transfer and names the address it imitates.',
      },
    ],
    limits: [
      "An address that imitates one you haven't saved and that isn't one of your wallets.",
      'A lookalike that differs within the first or last four characters.',
    ],
    live: true,
  },
};
