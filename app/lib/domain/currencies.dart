import 'package:intl/intl.dart';

/// Currency metadata + formatting. Amounts stay integer minor units
/// everywhere; this is presentation only.
class Currencies {
  static const supported = [
    ('USD', '\$', 'en_US'),
    ('EUR', '€', 'de_DE'),
    ('GBP', '£', 'en_GB'),
    ('INR', '₹', 'en_IN'),
    ('AED', 'د.إ', 'en_AE'),
    ('AUD', 'A\$', 'en_AU'),
    ('CAD', 'C\$', 'en_CA'),
    ('JPY', '¥', 'ja_JP'),
    ('SGD', 'S\$', 'en_SG'),
  ];

  static String symbolOf(String code) =>
      supported.where((c) => c.$1 == code).map((c) => c.$2).firstOrNull ?? '$code ';

  /// Formats minor units for display: ₹1,234.56 / ¥1,235 (no decimals).
  static String format(int minor, {String currency = 'USD'}) {
    final zeroDecimal = const {'JPY'};
    final f = NumberFormat.currency(
      locale: 'en_US',
      symbol: symbolOf(currency),
      decimalDigits: zeroDecimal.contains(currency) ? 0 : 2,
    );
    return f.format(minor / (zeroDecimal.contains(currency) ? 1 : 100));
  }
}
