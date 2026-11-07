import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;
import 'package:html/dom.dart' show Comment, Element;
import 'package:html/parser.dart' as html_parser;

/// The app's `index.html` prepared to receive pages.
///
/// [source] is the text as it came, served unchanged as the app shell.
/// [version] is the SHA-1 digest of [source] in hexadecimal: 40 lowercase
/// characters, for the log. [segments] are the four pieces of the document
/// without the managed tags: before the value of `lang` on `<html>`, between
/// it and the end of `<head>`, between the end of `<head>` and the start of
/// `<body>`, and the rest.
final class HtmlTemplate {
  HtmlTemplate._(this.source, this.version, this.segments);

  static const _langMark = 'crawlable-lang-7c1e9b';
  static const _headMark = 'crawlable-head-7c1e9b';
  static const _bodyMark = 'crawlable-body-7c1e9b';

  static final _head = RegExp(r'<head[\s>]', caseSensitive: false);
  static final _body = RegExp(r'<body[\s>]', caseSensitive: false);

  /// The text as it came, served unchanged as the app shell.
  final String source;

  /// The SHA-1 digest of [source] in hexadecimal.
  final String version;

  /// The four pieces of the document without the managed tags.
  final List<String> segments;

  /// Prepares [source]. Throws [FormatException] when the text has no
  /// explicit `<head>` and `<body>` or already contains one of the internal
  /// marks.
  static HtmlTemplate parse(String source) {
    if (!_head.hasMatch(source) || !_body.hasMatch(source)) {
      throw const FormatException(
        'The page template needs explicit <head> and <body> tags: the page '
        'head and body go into them. Use the index.html from the Flutter web '
        'build.',
      );
    }
    for (final mark in const [_langMark, _headMark, _bodyMark]) {
      if (source.contains(mark)) {
        throw FormatException(
          'The template contains the internal mark "$mark", used to cut the '
          'document. Remove that text from index.html.',
        );
      }
    }

    final doc = html_parser.parse(source);
    final head = doc.head!;
    for (final el in head.children.toList()) {
      if (_managed(el)) {
        el.remove();
      }
    }
    doc.documentElement!.attributes['lang'] = _langMark;
    head.append(Comment(_headMark));
    doc.body!.insertBefore(Comment(_bodyMark), doc.body!.firstChild);

    final html = doc.outerHtml;
    final a = _cut(html, 'lang="$_langMark"');
    final b = _cut(a.last, '<!--$_headMark-->');
    final c = _cut(b.last, '<!--$_bodyMark-->');
    final version = sha1.convert(utf8.encode(source)).toString();

    return HtmlTemplate._(source, version, [a.first, b.first, c.first, c.last]);
  }

  /// [html] split at [mark], which must appear exactly once.
  static List<String> _cut(String html, String mark) {
    final parts = html.split(mark);
    if (parts.length != 2) {
      throw StateError(
        'The mark "$mark" appeared ${parts.length - 1} times in the serialized '
        'template instead of once. The outerHtml output of package:html '
        'changed: review HtmlTemplate.parse.',
      );
    }
    return parts;
  }

  /// Whether [el] is a head tag that the page writes on its own.
  static bool _managed(Element el) {
    final name = el.attributes['name']?.toLowerCase();
    final property = el.attributes['property']?.toLowerCase();
    final rel = el.attributes['rel']?.toLowerCase();

    return switch (el.localName) {
      'title' => true,
      'meta' =>
        const {'description', 'robots', 'googlebot'}.contains(name) ||
            (name?.startsWith('twitter:') ?? false) ||
            (property?.startsWith('og:') ?? false),
      'link' =>
        rel == 'canonical' ||
            (rel == 'alternate' && el.attributes.containsKey('hreflang')),
      _ => false,
    };
  }
}
