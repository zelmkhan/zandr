// What the wallet shows and works with, as the extension's API types it (src/server/api.ts).
import 'config.dart';

class TokenInfo {
  final String? name, symbol, logo;
  final bool verified;
  final int? decimals;
  // The token has a market, so asking its price is worth a request.
  final bool traded;
  const TokenInfo({this.name, this.symbol, this.logo, required this.verified, this.decimals, required this.traded});
}

class Price {
  final double price;
  final double? change24h;
  const Price(this.price, this.change24h);
}

class Coin {
  // SOL itself carries the wrapped SOL mint, which its price is listed under, and `native`.
  final String mint;
  final bool native;
  final String program; // system | token | token-2022
  final String amount; // smallest unit
  final int decimals;
  final String balance; // as wallets show it
  final String? name, symbol, logo;
  final bool verified;
  final double? price, value, change24h;
  const Coin({
    required this.mint,
    required this.native,
    required this.program,
    required this.amount,
    required this.decimals,
    required this.balance,
    this.name,
    this.symbol,
    this.logo,
    required this.verified,
    this.price,
    this.value,
    this.change24h,
  });

  String get label => symbol ?? name ?? 'Unknown token';

  Map<String, Object?> toJson() => {
        'mint': mint, 'native': native, 'program': program, 'amount': amount, 'decimals': decimals, 'balance': balance,
        'name': name, 'symbol': symbol, 'logo': logo, 'verified': verified, 'price': price, 'value': value, 'change24h': change24h,
      };

  factory Coin.fromJson(Map<String, Object?> json) => Coin(
        mint: json['mint'] as String,
        native: json['native'] as bool,
        program: json['program'] as String,
        amount: json['amount'] as String,
        decimals: json['decimals'] as int,
        balance: json['balance'] as String,
        name: json['name'] as String?,
        symbol: json['symbol'] as String?,
        logo: json['logo'] as String?,
        verified: json['verified'] as bool,
        price: (json['price'] as num?)?.toDouble(),
        value: (json['value'] as num?)?.toDouble(),
        change24h: (json['change24h'] as num?)?.toDouble(),
      );
}

class Portfolio {
  final Network network;
  final String address;
  // SOL first, even with nothing in it, then by value.
  final List<Coin> coins;
  final double value;
  final DateTime updatedAt;
  const Portfolio({required this.network, required this.address, required this.coins, required this.value, required this.updatedAt});

  Map<String, Object?> toJson() => {
        'network': network.name, 'address': address, 'coins': [for (final coin in coins) coin.toJson()],
        'value': value, 'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  factory Portfolio.fromJson(Map<String, Object?> json) => Portfolio(
        network: Network.values.byName(json['network'] as String),
        address: json['address'] as String,
        coins: [for (final coin in json['coins'] as List) Coin.fromJson((coin as Map).cast())],
        value: (json['value'] as num).toDouble(),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int),
      );
}

// A token from the list or a search, to swap into.
class TokenListing {
  final String mint;
  final TokenInfo info;
  const TokenListing(this.mint, this.info);
}

// Why a call to a service failed.
enum ServiceFailure { forbidden, rateLimited, unreachable, badResponse, invalidRequest }

class ServiceError implements Exception {
  final ServiceFailure reason;
  final String service; // rpc | tokens | zandr
  final String? detail;
  const ServiceError(this.reason, this.service, [this.detail]);

  @override
  String toString() => '$service: ${reason.name}${detail == null ? '' : ' ($detail)'}';
}
