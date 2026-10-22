// Live coins (src/lib/live.ts). While the wallet is on screen, a WebSocket to the node is kept open,
// subscribed to the wallet's own account (its SOL) and its token accounts under both token
// programs. When the node reports a change, the coins are fetched again right away, at least as
// new as the change. Where the node has no socket, or it drops, the coins are fetched every few
// seconds instead until the socket is back.
import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'config.dart';
import 'solana/addresses.dart';

// Without a live socket: how often the coins are fetched instead.
const _pollEvery = Duration(seconds: 5);
// A request this often, which the node answers: a socket that stops answering is replaced.
const _heartbeat = Duration(seconds: 20);
// Waits before connecting again, longer each time in a row the socket fails.
const _retry = [Duration(seconds: 1), Duration(seconds: 3), Duration(seconds: 10), Duration(seconds: 30)];
// One transaction changes several accounts, each reported on its own: one refresh for them all.
const _settle = Duration(milliseconds: 150);

// The wallet's own account, then its token accounts: the wallet is the owner, 32 bytes in.
List<Map<String, Object>> _subscriptions(String address) {
  final owned = {'memcmp': {'offset': 32, 'bytes': address}};
  return [
    {'method': 'accountSubscribe', 'params': [address, {'commitment': 'processed', 'encoding': 'base64'}]},
    {'method': 'programSubscribe', 'params': [tokenProgram, {'commitment': 'processed', 'encoding': 'base64', 'filters': [{'dataSize': 165}, owned]}]},
    {'method': 'programSubscribe', 'params': [token2022Program, {'commitment': 'processed', 'encoding': 'base64', 'filters': [owned]}]},
  ];
}

// Watches `address` through the node at `rpc` until stopped: `refresh` is called with the slot of
// the change (null when polling or just connected).
class LiveWatch {
  final String address;
  final String url;
  final void Function(int? changedIn) refresh;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _listening;
  Timer? _poll, _beat, _settleTimer, _retryTimer;
  bool _live = false, _stopped = false;
  int _failures = 0, _subscribed = 0, _slot = 0;
  DateTime _heard = DateTime.now();

  LiveWatch(this.address, String rpc, this.refresh) : url = socketUrl(rpc) {
    _poll = Timer.periodic(_pollEvery, (_) {
      if (!_live) refresh(null);
    });
    _connect();
  }

  void _connect() {
    _subscribed = 0;
    final requests = _subscriptions(address);
    try {
      final socket = WebSocketChannel.connect(Uri.parse(url));
      _socket = socket;
      _listening = socket.stream.listen((data) => _receive(data, requests.length), onDone: _drop, onError: (_) => _drop(), cancelOnError: true);
      socket.ready.then((_) {
        if (_socket != socket) return;
        _heard = DateTime.now();
        for (final (i, request) in requests.indexed) {
          socket.sink.add(jsonEncode({'jsonrpc': '2.0', 'id': i + 1, ...request}));
        }
        _beat = Timer.periodic(_heartbeat, (_) => _ping());
      }, onError: (_) => _drop());
    } catch (_) {
      _drop();
    }
  }

  void _receive(Object? data, int count) {
    _heard = DateTime.now();
    Object? message;
    try {
      message = jsonDecode('$data');
    } on FormatException {
      return;
    }
    if (message is! Map) return;
    final id = message['id'];
    // The answers to the subscriptions: without all of them, changes could go unseen.
    if (id is int && id >= 1 && id <= count) {
      if (!message.containsKey('result')) return _drop();
      if (++_subscribed < count) return;
      _live = true;
      _failures = 0;
      // Whatever changed before the subscriptions were in place.
      refresh(null);
      return;
    }
    // A change: refresh once the transaction's other changes are in too, from its slot on.
    final method = message['method'];
    if (method is String && method.endsWith('Notification')) {
      final reported = (((message['params'] as Map?)?['result'] as Map?)?['context'] as Map?)?['slot'];
      if (reported is int && reported > _slot) _slot = reported;
      _settleTimer?.cancel();
      _settleTimer = Timer(_settle, () => refresh(_slot == 0 ? null : _slot));
    }
  }

  // Solana's sockets have no ping. A method they don't know gets an error back, which is all a
  // heartbeat needs.
  void _ping() {
    if (DateTime.now().difference(_heard) > _heartbeat * 2) return _drop();
    _socket?.sink.add(jsonEncode({'jsonrpc': '2.0', 'id': 0, 'method': 'ping'}));
  }

  // The socket closed, failed or went quiet: poll meanwhile, and connect again in a while.
  void _drop() {
    _live = false;
    _beat?.cancel();
    _listening?.cancel();
    _socket?.sink.close();
    _socket = null;
    _listening = null;
    if (_stopped) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(_retry[_failures < _retry.length ? _failures : _retry.length - 1], _connect);
    _failures++;
  }

  void stop() {
    _stopped = true;
    _poll?.cancel();
    _settleTimer?.cancel();
    _retryTimer?.cancel();
    _drop();
  }
}
