// The one HTTP client the app talks through: to zandr's server, Jupiter behind it, and the node.
// On the iPhone it's the system's own networking (NSURLSession), which speaks HTTP/2 with zandr's
// server, so requests made at once share one connection and one TLS handshake, and it keeps that
// connection open between requests. Elsewhere (tests, the browser preview) it's Dart's, holding
// idle connections for minutes rather than the default 15 seconds.
export 'net_io.dart' if (dart.library.js_interop) 'net_web.dart';
