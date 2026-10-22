// How amounts, addresses and names read on screen, as the extension shows them (src/lib/format.ts).
import 'package:intl/intl.dart';

// Shortened as xxxx...xxxxxx, the way addresses are shown in the wallet.
String shortAddress(String address) => address.length <= 12 ? address : '${address.substring(0, 4)}...${address.substring(address.length - 6)}';

// Two letters for a wallet's or an address's avatar: the first letters of the name's first two
// words, or the first two of a one-word name; without a name, the address's first two characters.
String monogram(String? name, String address) {
  final words = (name ?? '').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return String.fromCharCodes(address.runes.take(2));
  final letters = words.length > 1 ? [String.fromCharCode(words[0].runes.first), String.fromCharCode(words[1].runes.first)] : [String.fromCharCodes(words[0].runes.take(2))];
  return letters.join().toUpperCase();
}

final _usd = NumberFormat.currency(locale: 'en_US', symbol: r'$');
final _compact = NumberFormat.compact(locale: 'en_US')..maximumFractionDigits = 2;

// US dollars, cents included; a sliver under a cent shows as such rather than as $0.00.
String formatUsd(double value) => value > 0 && value < 0.01 ? r'<$0.01' : _usd.format(value);

// A token amount with as many decimals as are worth reading: fewer for large amounts, more for
// small ones, and billions shortened (1.5B).
String formatAmount(String balance) {
  final amount = double.tryParse(balance) ?? 0;
  if (amount == 0) return '0';
  if (amount < 0.000001) return '<0.000001';
  if (amount >= 1e9) return _compact.format(amount);
  final digits = amount >= 1000
      ? 2
      : amount >= 1
      ? 4
      : 6;
  return (NumberFormat.decimalPattern('en_US')..maximumFractionDigits = digits).format(amount);
}

// A price change in percent, signed: +2.31%, -0.96%.
String formatChange(double percent) {
  final text = percent.abs().toStringAsFixed(2);
  return percent > 0
      ? '+$text%'
      : percent < 0
      ? '-$text%'
      : '$text%';
}

String timeAgo(DateTime time) {
  final elapsed = DateTime.now().difference(time);
  if (elapsed.inMinutes < 1) return 'Just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} min ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours} h ago';
  if (elapsed.inDays < 7) return '${elapsed.inDays} d ago';
  return DateFormat.yMMMd('en_US').format(time);
}
