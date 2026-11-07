/// A page route: literal segments and `:name` segments. A path matches
/// without regard to case and ignoring slashes at either end; each `:name`
/// takes one whole, non-empty segment, percent-decoded.
final class HtmlRoute {
  HtmlRoute._(this.pattern, this._segments);

  static final _name = RegExp(r'^[a-z_][a-z0-9_]*$');

  /// The route as declared, such as `/:lang/gym/:id`.
  final String pattern;

  final List<String> _segments;

  /// Parses [pattern], which starts with `/` and is lowercase. Throws
  /// [StateError] for an empty segment, a segment with `*`, a parameter
  /// name outside `[a-z_][a-z0-9_]*` or a repeated parameter name.
  static HtmlRoute parse(String pattern) {
    final segments = pattern == '/'
        ? const <String>[]
        : pattern.substring(1).split('/');
    final names = <String>{};
    for (final segment in segments) {
      final param = segment.startsWith(':') ? segment.substring(1) : null;
      if (segment.isEmpty ||
          segment.contains('*') ||
          (param != null && (!_name.hasMatch(param) || !names.add(param)))) {
        throw StateError(
          'The page route "$pattern" is invalid: use literal segments and '
          ':name parameters (/:lang/gym/:id), with no empty segment, no "*" '
          'and no repeated name.',
        );
      }
    }
    return HtmlRoute._(pattern, segments);
  }

  /// The decoded parameters of [path], a percent-encoded path as in
  /// `Uri.path`, or null when it does not match.
  Map<String, String>? match(String path) {
    var start = 0;
    var end = path.length;
    while (start < end && path.codeUnitAt(start) == 0x2F) {
      start++;
    }
    while (end > start && path.codeUnitAt(end - 1) == 0x2F) {
      end--;
    }
    final trimmed = path.substring(start, end);
    final parts = trimmed.isEmpty ? const <String>[] : trimmed.split('/');
    if (parts.length != _segments.length) {
      return null;
    }
    final params = <String, String>{};
    for (var i = 0; i < parts.length; i++) {
      final value = _decode(parts[i]);
      final segment = _segments[i];
      if (value == null || value.isEmpty) {
        return null;
      }
      if (segment.startsWith(':')) {
        params[segment.substring(1)] = value;
      } else if (value.toLowerCase() != segment) {
        return null;
      }
    }
    return params;
  }

  /// [part] percent-decoded, or null when its encoding is malformed.
  static String? _decode(String part) {
    try {
      return Uri.decodeComponent(part);
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }
}
