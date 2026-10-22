// Where the wallet talks to: zandr's API server (the default node, Jupiter with zandr's key, token
// logos, exchange lists and address checks), as the extension does (src/lib/network.ts).
import 'package:http/http.dart' as http;

const zandrApi = 'https://api.zandr.xyz';

// The answer Railway, which hosts zandr's server, gives in its place while the server isn't
// running: a 404 marked x-railway-fallback. It means the server can't answer, not that it refused.
bool serverAbsent(http.BaseResponse response) => response.headers['x-railway-fallback'] == 'true';

enum Network { mainnet, devnet }

// The version, as pubspec.yaml has it (test/data_test.dart keeps them the same).
const appVersion = '1.0.0';

// Each network's first block, by which a node tells which chain it serves.
const genesisHash = {
  Network.mainnet: '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d',
  Network.devnet: 'EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG',
};

const defaultRpc = {
  Network.mainnet: '$zandrApi/rpc/mainnet',
  Network.devnet: 'https://api.devnet.solana.com',
};

// The node's WebSocket: the same address over ws(s). A node on an explicit port (a local test
// validator's 8899) serves it one port up, as web3.js assumes too.
String socketUrl(String rpc) {
  final url = Uri.parse(rpc);
  return url.replace(scheme: url.scheme == 'https' ? 'wss' : 'ws', port: url.hasPort ? url.port + 1 : null).toString();
}

const logoServer = '$zandrApi/v1/logo';
const jupiterViaZandr = '$zandrApi/jupiter';
const jupiterPublic = 'https://lite-api.jup.ag';

// Public services, for those who'd rather nothing about their wallet went through zandr's server:
// Helius's mainnet node under a key meant to be public, Jupiter's keyless API, and logos through
// wsrv.nl, an open image proxy (so a token's creator still never sees who looks). Only the
// exchanges' token lists still come from zandr's server, fetched whole, so it learns nothing.
const publicRpcMainnet = 'https://mainnet.helius-rpc.com/?api-key=c987b612-49bb-4f4d-b716-cf82ae436e53';
// Sized for the largest logo the app shows (56 points) on a 3x screen; SVGs come back as PNGs.
// Should the source fail, wsrv.nl redirects to `fallback`.
String proxiedLogo(String source, {String? fallback}) =>
    'https://wsrv.nl/?url=${Uri.encodeComponent(source)}&w=192&h=192&output=png${fallback == null ? '' : '&default=${Uri.encodeComponent(fallback)}'}';

String explorerTransaction(String signature, Network network) =>
    'https://solscan.io/tx/$signature${network == Network.devnet ? '?cluster=devnet' : ''}';
