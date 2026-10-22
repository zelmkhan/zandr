import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client appHttpClient() {
  if (Platform.isIOS) {
    // Ephemeral: nothing it fetches is kept on disk, not even in the HTTP cache.
    final config = URLSessionConfiguration.ephemeralSessionConfiguration()..timeoutIntervalForRequest = const Duration(seconds: 20);
    return CupertinoClient.fromSessionConfiguration(config);
  }
  return IOClient(HttpClient()..idleTimeout = const Duration(minutes: 5));
}
