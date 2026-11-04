/// Stable identity rules shared by pricing and model display aggregation.
class ModelIdentity {
  const ModelIdentity._();

  /// Removes a provider prefix (the first `provider/`) and a terminal `-free`.
  /// It deliberately does not normalize punctuation, versions, or near matches.
  static String normalize(String model) {
    var value = model.trim();
    final slash = value.indexOf('/');
    if (slash >= 0) value = value.substring(slash + 1);
    if (value.toLowerCase().endsWith('-free')) {
      value = value.substring(0, value.length - 5);
    }
    return value.toLowerCase();
  }

  static bool matches(String left, String right) =>
      normalize(left) == normalize(right);
}
