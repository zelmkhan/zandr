// Amounts as decimal strings and in a token's smallest unit, exactly (src/lib/units.ts).

// 1234500 with 6 decimals is "1.2345".
String formatUnits(BigInt amount, int decimals) {
  final negative = amount.isNegative;
  final digits = amount.abs().toString().padLeft(decimals + 1, '0');
  final whole = digits.substring(0, digits.length - decimals);
  final fraction = digits.substring(digits.length - decimals).replaceAll(RegExp(r'0+$'), '');
  return '${negative ? '-' : ''}${fraction.isEmpty ? whole : '$whole.$fraction'}';
}

// "1.2345" with 6 decimals is 1234500; null for text that isn't such an amount, or has more
// decimals than the token.
BigInt? parseUnits(String text, int decimals) {
  final value = text.trim();
  if (!RegExp(r'^\d*\.?\d*$').hasMatch(value) || value.isEmpty || value == '.') return null;
  final [whole, fraction] = value.contains('.') ? value.split('.') : [value, ''];
  if (fraction.length > decimals) return null;
  return BigInt.parse('${whole.isEmpty ? '0' : whole}${fraction.padRight(decimals, '0')}');
}

// The sum of two non-negative decimal strings.
String addDecimals(String a, String b) {
  int places(String value) => value.contains('.') ? value.split('.')[1].length : 0;
  final p = places(a) > places(b) ? places(a) : places(b);
  BigInt units(String value) {
    final [whole, fraction] = value.contains('.') ? value.split('.') : [value, ''];
    return BigInt.parse(whole + fraction.padRight(p, '0'));
  }

  return formatUnits(units(a) + units(b), p);
}
