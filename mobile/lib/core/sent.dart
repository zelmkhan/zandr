// Transactions the wallet sent (transfers, swaps, reclaims), followed until they land
// (src/lib/sent.ts). Each is watched over the node's WebSocket (signatureSubscribe), so the screen
// learns the moment a node has run it; asking the node every second stays as the fallback, and is
// what sends it again while it hasn't landed: under load the network drops transactions rather
// than queueing them.
import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'config.dart';
import 'solana/rpc.dart';

// What's needed to send it again until its blockhash runs out.
class Pending {
  final String wire; // base64
  final int lastValidBlockHeight;
  const Pending(this.wire, this.lastValidBlockHeight);
}

enum SettledStatus { confirmed, failed, expired }

// How a transaction ended: landed, failed (the fee paid), or expired unsent.
class Settled {
  final SettledStatus status;
  final String? detail;
  const Settled(this.status, [this.detail]);
}

const _askEvery = Duration(seconds: 1);
// A blockhash is good for about a minute and a half: past that, a transaction can't land.
const _watchFor = Duration(seconds: 90);

Settled _settledBy(Object? err) =>
    err == null ? const Settled(SettledStatus.confirmed) : Settled(SettledStatus.failed, () { final text = jsonEncode(err); return text.length > 200 ? text.substring(0, 200) : text; }());

// Follows `signature` until it lands, fails or expires; `cancel` completing stops it (null then).
Future<Settled?> followSent(Rpc rpc, String signature, Pending pending, {Future<void>? cancel}) async {
  final done = Completer<Settled?>();
  void settle(Settled? result) {
    if (!done.isCompleted) done.complete(result);
  }

  cancel?.then((_) => settle(null));
  Future<void> ask() async {
    final result = await rpc.call<Map<String, dynamic>>('getSignatureStatuses', [
      [signature],
    ]);
    final status = (result['value'] as List).firstOrNull as Map?;
    // Done once a node has run it in a block (processed): the soonest the result is known.
    if (status != null && (status['err'] != null || status['confirmationStatus'] != null)) settle(_settledBy(status['err']));
  }

  // The socket: the node says the moment it's processed.
  WebSocketChannel? socket;
  try {
    socket = WebSocketChannel.connect(Uri.parse(socketUrl(rpc.url)));
    socket.sink.add(jsonEncode({
      'jsonrpc': '2.0', 'id': 1, 'method': 'signatureSubscribe',
      'params': [signature, {'commitment': 'processed'}],
    }));
    socket.stream.listen(
      (data) {
        Object? message;
        try {
          message = jsonDecode('$data');
        } on FormatException {
          return;
        }
        if (message is! Map) return;
        // Landed before the subscription was in place: the node wouldn't tell any more.
        if (message['id'] == 1 && message['error'] == null) ask().ignore();
        if (message['method'] != 'signatureNotification') return;
        final value = ((message['params'] as Map?)?['result'] as Map?)?['value'];
        if (value is Map && value.containsKey('err')) settle(_settledBy(value['err']));
      },
      onError: (_) {},
      cancelOnError: true,
    );
  } catch (_) {
    socket = null;
  }

  // The fallback, and sending it again meanwhile.
  final until = DateTime.now().add(_watchFor);
  () async {
    while (!done.isCompleted) {
      await Future.any([Future<void>.delayed(_askEvery), done.future]);
      if (done.isCompleted) break;
      try {
        await ask();
        if (done.isCompleted) break;
        final height = await rpc.call<int>('getBlockHeight', [
          {'commitment': 'confirmed'},
        ]);
        if (height > pending.lastValidBlockHeight) {
          // One last look: it may have landed in the very last blocks.
          await ask();
          settle(const Settled(SettledStatus.expired));
          break;
        }
        rpc.call<String>('sendTransaction', [
          pending.wire,
          {'encoding': 'base64', 'skipPreflight': true, 'maxRetries': 0},
        ]).ignore();
      } catch (_) {
        // The node can't be reached right now: the next round tries again.
        if (DateTime.now().isAfter(until.add(_watchFor))) settle(const Settled(SettledStatus.expired, 'The network could not be reached'));
      }
    }
  }();

  final result = await done.future;
  await socket?.sink.close();
  return result;
}
