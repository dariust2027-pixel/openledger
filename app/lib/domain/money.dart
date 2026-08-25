import 'package:intl/intl.dart';

/// Money stored as integer minor units (cents) + ISO currency code.
/// Never use doubles for money.
class Money {
  final int minorUnits;
  final String currency;

  const Money(this.minorUnits, {this.currency = 'USD'});

  static const zeroUSD = Money(0);

  factory Money.fromMajor(num major, {String currency = 'USD'}) =>
      Money((major * 100).round(), currency: currency);

  double get asDouble => minorUnits / 100.0;

  Money operator +(Money other) => Money(minorUnits + other.minorUnits, currency: currency);
  Money operator -(Money other) => Money(minorUnits - other.minorUnits, currency: currency);

  bool get isNegative => minorUnits < 0;

  String formatted({String? locale}) {
    final f = NumberFormat.currency(locale: locale ?? 'en_US', symbol: '\$', decimalDigits: 2);
    return f.format(asDouble);
  }

  @override
  String toString() => 'Money(${minorUnits}minor, $currency)';
}
