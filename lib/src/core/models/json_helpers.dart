/// Small helpers shared by the model JSON codecs.
T enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is! String) return fallback;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

T? enumByNameOrNull<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

double? optDouble(Object? v) => v is num ? v.toDouble() : null;

double reqDouble(Object? v, String field) {
  if (v is num) return v.toDouble();
  throw FormatException('Expected number for "$field", got ${v.runtimeType}');
}

String reqString(Object? v, String field) {
  if (v is String) return v;
  throw FormatException('Expected string for "$field", got ${v.runtimeType}');
}

Map<String, dynamic> asJsonMap(Object? v, String field) {
  if (v is Map) return Map<String, dynamic>.from(v);
  throw FormatException('Expected object for "$field", got ${v.runtimeType}');
}

List<dynamic> asJsonList(Object? v) => v is List ? v : const [];

DateTime reqDate(Object? v, String field) {
  final parsed = v is String ? DateTime.tryParse(v) : null;
  if (parsed == null) throw FormatException('Expected ISO-8601 date for "$field"');
  return parsed;
}
