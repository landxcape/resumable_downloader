/// A filesystem-safe V2 identity used for partial data and manifests.
class TransferKey {
  factory TransferKey(String value) {
    if (!_validPattern.hasMatch(value)) {
      throw ArgumentError.value(value, 'value', 'must be filesystem-safe');
    }
    return TransferKey._(value);
  }

  const TransferKey._(this.value);

  static final RegExp _validPattern = RegExp(r'^[A-Za-z0-9_-]+$');

  final String value;

  @override
  bool operator ==(Object other) => other is TransferKey && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
