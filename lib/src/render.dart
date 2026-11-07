import 'package:html/html_escape.dart' show htmlSerializeEscape;

import 'body.dart';
import 'page.dart';
import 'template.dart';

/// Builds the HTML of a page on top of an [HtmlTemplate].
abstract final class HtmlRender {
  static final _lang = RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$');

  /// [origin] is the site's public origin (`https://example.org`) and
  /// [requested] the requested path with the declared parameters, the base of
  /// the default canonical URL. [onUrlDropped] receives each unsafe URL the
  /// body writer drops. Throws [ArgumentError] for an invalid language, an
  /// empty title, a URL on another origin and a body outside the allowlist.
  static String page(
    HtmlTemplate template,
    HtmlPage page, {
    required Uri origin,
    required Uri requested,
    void Function(String tag, String attribute)? onUrlDropped,
  }) {
    checkLang(page.lang);
    if (page.title.trim().isEmpty) {
      throw ArgumentError(
        'The page for ${requested.path} has no title: <title> is what search '
        'engines show. Fill HtmlPage.title.',
      );
    }
    final canonical = page.canonical == null
        ? defaultCanonical(origin, requested)
        : resolve(origin, page.canonical!);
    final head = StringBuffer()
      ..write('<title>${_text(page.title)}</title>')
      ..write(_meta('name', 'description', page.description))
      ..write('<link rel="canonical" href="${_attr('$canonical')}">');
    for (final alt in page.alternates) {
      if (alt.hreflang != 'x-default') {
        checkLang(alt.hreflang);
      }
      head.write(
        '<link rel="alternate" hreflang="${_attr(alt.hreflang)}" '
        'href="${_attr('${resolve(origin, alt.href)}')}">',
      );
    }
    if (!page.robots.isDefault) {
      head.write(_meta('name', 'robots', page.robots.content));
    }
    final social = page.social;
    if (social != null) {
      final image = social.image == null
          ? null
          : resolve(origin, social.image!, anyOrigin: true);
      head
        ..write(_meta('property', 'og:title', page.title))
        ..write(_meta('property', 'og:description', page.description))
        ..write(_meta('property', 'og:url', '$canonical'))
        ..write(_meta('property', 'og:type', social.type))
        ..write(_meta('property', 'og:site_name', social.siteName))
        ..write(_meta('property', 'og:locale', social.locale))
        ..write(_meta('property', 'og:image', image?.toString()))
        ..write(_meta('property', 'og:image:alt', social.imageAlt))
        ..write(
          _meta(
            'name',
            'twitter:card',
            image == null ? 'summary' : 'summary_large_image',
          ),
        );
    }
    final body = StringBuffer();
    if (page.body case final root?) {
      HtmlBodyWriter.write(root, body, onUrlDropped: onUrlDropped);
    }

    return _join(template, page.lang, '$head', '$body');
  }

  /// The shell for [HtmlNotFound]: no body, with `noindex`, and the language
  /// and title when given.
  static String notFound(HtmlTemplate template, HtmlNotFound answer) {
    final lang = answer.lang ?? 'en';
    checkLang(lang);
    final head = StringBuffer()
      ..write(_meta('name', 'robots', 'noindex, follow'));
    if (answer.title case final title? when title.trim().isNotEmpty) {
      head.write('<title>${_text(title)}</title>');
    }
    return _join(template, lang, '$head', '');
  }

  /// [path] resolved against [origin]. A URL on another origin throws
  /// [ArgumentError], unless [anyOrigin] (an image), which accepts any
  /// `http`/`https` URL.
  static Uri resolve(Uri origin, String path, {bool anyOrigin = false}) {
    final uri = origin.resolve(path);
    final same =
        uri.scheme == origin.scheme &&
        uri.host == origin.host &&
        uri.port == origin.port;
    final web = uri.scheme == 'http' || uri.scheme == 'https';
    if (same || (anyOrigin && web)) {
      return uri;
    }
    throw ArgumentError(
      'The URL "$path" is not on the origin $origin: canonical URLs, language '
      'versions, redirects and sitemap entries only point to this site. Use a '
      'path such as /en/gym/12.',
    );
  }

  /// The canonical URL without `HtmlPage.canonical`: the origin with the
  /// requested path and the declared parameters in alphabetical order.
  static Uri defaultCanonical(Uri origin, Uri requested) {
    final keys = requested.queryParameters.keys.toList()..sort();
    return origin.replace(
      path: requested.path,
      queryParameters: keys.isEmpty
          ? null
          : {for (final k in keys) k: requested.queryParameters[k]!},
    );
  }

  /// Throws [ArgumentError] when [lang] does not have the shape of a BCP 47
  /// tag.
  static void checkLang(String lang) {
    if (!_lang.hasMatch(lang)) {
      throw ArgumentError(
        'Invalid language "$lang": use a BCP 47 tag such as en, en-US or '
        'pt-BR.',
      );
    }
  }

  /// The template with [lang], [head] and [body] in their places.
  static String _join(HtmlTemplate t, String lang, String head, String body) {
    final s = t.segments;
    return '${s[0]}lang="${_attr(lang)}"${s[1]}$head${s[2]}$body${s[3]}';
  }

  /// A `<meta>` with [key] equal to [name], or nothing when [content] is
  /// empty.
  static String _meta(String key, String name, String? content) =>
      content == null || content.isEmpty
      ? ''
      : '<meta $key="$name" content="${_attr(content)}">';

  static String _text(String v) => htmlSerializeEscape(v);

  static String _attr(String v) => htmlSerializeEscape(v, attributeMode: true);
}
