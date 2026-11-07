import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' show Comment, Element, Text;
import 'package:html/parser.dart' as html_parser;
import 'package:make_it_crawlable/src/body.dart';
import 'package:make_it_crawlable/src/page.dart';
import 'package:make_it_crawlable/src/render.dart';
import 'package:make_it_crawlable/src/template.dart';
import 'package:test/test.dart';

const _source = '''
<!DOCTYPE html>
<html lang="fr">
<head>
  <base href="/">
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Template</title>
  <meta name="description" content="Generic description">
  <meta property="og:title" content="Generic title">
  <meta name="Twitter:Card" content="summary">
  <link rel="canonical" href="https://example.org/">
  <link rel="alternate" hreflang="pt" href="https://example.org/pt">
  <link rel="manifest" href="manifest.json">
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
''';

final _origin = Uri.parse('https://example.org');

final _template = HtmlTemplate.parse(_source);

/// The minimal page at `/en/gym/12`, with the given fields.
String _render({
  String lang = 'en',
  String title = 'Gym',
  String? description,
  String? canonical,
  List<HtmlAlternate> alternates = const [],
  HtmlRobots robots = const HtmlRobots(),
  HtmlSocial? social,
  Element? body,
  String requested = '/en/gym/12',
}) => HtmlRender.page(
  _template,
  HtmlPage(
    lang: lang,
    title: title,
    description: description,
    canonical: canonical,
    alternates: alternates,
    robots: robots,
    social: social,
    body: body,
  ),
  origin: _origin,
  requested: Uri.parse(requested),
);

/// The body that [HtmlBodyWriter] writes for [root]; each dropped URL goes to
/// [dropped] as `tag attribute`.
String _body(Element root, [List<String>? dropped]) {
  final out = StringBuffer();
  HtmlBodyWriter.write(
    root,
    out,
    onUrlDropped: (tag, attribute) => dropped?.add('$tag $attribute'),
  );

  return '$out';
}

/// The first element of the fragment [html].
Element _fragment(String html) =>
    html_parser.parseFragment(html).children.first;

void main() {
  group('template', () {
    final empty = HtmlRender.notFound(_template, const HtmlNotFound());

    test('keeps the doctype', () {
      expect(empty.toLowerCase(), startsWith('<!doctype html>'));
    });

    test('keeps <base href>', () {
      expect(empty, contains('<base href="/">'));
    });

    test('removes title, description, og:title, twitter:card, canonical and '
        'alternate with hreflang', () {
      final page = _render();
      expect(page, isNot(contains('<title>Template')));
      expect(page, isNot(contains('Generic description')));
      expect(page, isNot(contains('Generic title')));
      expect(page.toLowerCase(), isNot(contains('twitter:card')));
      expect(page, isNot(contains('href="https://example.org/"')));
      expect(page, isNot(contains('https://example.org/pt')));
      expect('<title>'.allMatches(page), hasLength(1));
    });

    test('keeps viewport and manifest', () {
      expect(empty, contains('name="viewport"'));
      expect(empty, contains('rel="manifest"'));
    });

    test('replaces the lang of <html> with the page one', () {
      final page = _render();
      expect(page, contains('<html lang="en">'));
      expect(page, isNot(contains('lang="fr"')));
    });

    test('source is the input text', () {
      expect(_template.source, _source);
    });

    test('version is stable for the same text and changes with another', () {
      expect(HtmlTemplate.parse(_source).version, _template.version);
      expect(
        HtmlTemplate.parse('$_source\n').version,
        isNot(_template.version),
      );
    });

    test('version is the hex SHA-1 of the source', () {
      expect(_template.version, sha1.convert(utf8.encode(_source)).toString());
      expect(_template.version, matches(RegExp(r'^[0-9a-f]{40}$')));
    });

    test('no <body> throws FormatException', () {
      expect(
        () => HtmlTemplate.parse('<html><head></head></html>'),
        throwsFormatException,
      );
    });

    test('<header> without <head> throws FormatException', () {
      expect(
        () => HtmlTemplate.parse('<html><header></header><body></body></html>'),
        throwsFormatException,
      );
    });

    test('internal mark in the text throws FormatException', () {
      expect(
        () => HtmlTemplate.parse(
          '<html><head></head><body>crawlable-head-7c1e9b</body></html>',
        ),
        throwsFormatException,
      );
    });

    test('script async comes back as async=""', () {
      expect(
        empty,
        contains('<script src="flutter_bootstrap.js" async=""></script>'),
      );
    });

    test('the real Flutter index.html is prepared and keeps the scripts', () {
      final file = File('test/fixtures/flutter_index.html');
      expect(file.existsSync(), isTrue, reason: 'missing ${file.path}');
      final flutter = HtmlTemplate.parse(file.readAsStringSync());
      final page = HtmlRender.page(
        flutter,
        const HtmlPage(lang: 'en-US', title: 'Home'),
        origin: _origin,
        requested: Uri.parse('/'),
      );
      expect(page, contains('flutter_bootstrap.js'));
      expect(page, contains(r'<base href="$FLUTTER_BASE_HREF">'));
      expect(page, contains('<html lang="en-US">'));
      expect(page, contains('<title>Home</title>'));
      expect(page, isNot(contains('example_app</title>')));
    });
  });

  group('head', () {
    test('title is written with text escaping', () {
      expect(
        _render(title: '<b>&"'),
        contains('<title>&lt;b&gt;&amp;"</title>'),
      );
    });

    test('description is written with attribute escaping', () {
      expect(
        _render(description: 'a<b>"c'),
        contains('<meta name="description" content="a<b>&quot;c">'),
      );
    });

    test('no description means no description meta', () {
      expect(_render(), isNot(contains('name="description"')));
      expect(_render(description: ''), isNot(contains('name="description"')));
    });

    test('default canonical carries the parameters in alphabetical order', () {
      expect(
        _render(requested: '/en/search?z=1&a=b%20c'),
        contains(
          '<link rel="canonical" '
          'href="https://example.org/en/search?a=b+c&amp;z=1">',
        ),
      );
    });

    test('relative canonical is resolved against the origin', () {
      expect(
        _render(canonical: '/en/gym/12'),
        contains('<link rel="canonical" href="https://example.org/en/gym/12">'),
      );
    });

    test('canonical on another origin throws', () {
      expect(
        () => _render(canonical: 'https://other.example.org/x'),
        throwsArgumentError,
      );
      expect(
        () => _render(canonical: '//other.example.org/x'),
        throwsArgumentError,
      );
    });

    test('language versions accept x-default', () {
      final page = _render(
        alternates: const [
          HtmlAlternate('en-US', '/en/gym/12'),
          HtmlAlternate('x-default', '/gym/12'),
        ],
      );
      expect(
        page,
        contains(
          '<link rel="alternate" hreflang="en-US" '
          'href="https://example.org/en/gym/12">',
        ),
      );
      expect(
        page,
        contains(
          '<link rel="alternate" hreflang="x-default" '
          'href="https://example.org/gym/12">',
        ),
      );
    });

    test('invalid hreflang throws', () {
      expect(
        () => _render(alternates: const [HtmlAlternate('english', '/en')]),
        throwsArgumentError,
      );
    });

    test('invalid lang throws', () {
      expect(() => _render(lang: 'english'), throwsArgumentError);
      expect(() => _render(lang: ''), throwsArgumentError);
    });

    test('empty title throws', () {
      expect(() => _render(title: '  '), throwsArgumentError);
    });

    test('robots is written only with noindex or nofollow', () {
      expect(_render(), isNot(contains('name="robots"')));
      expect(
        _render(robots: const HtmlRobots(index: false)),
        contains('<meta name="robots" content="noindex, follow">'),
      );
      expect(
        _render(robots: const HtmlRobots(follow: false)),
        contains('<meta name="robots" content="index, nofollow">'),
      );
    });

    test('social with an image writes og:* and summary_large_image', () {
      final page = _render(
        description: 'Description',
        social: const HtmlSocial(
          siteName: 'Example',
          locale: 'en_US',
          image: '/img/12.jpg',
          imageAlt: 'Front',
        ),
      );
      expect(page, contains('<meta property="og:title" content="Gym">'));
      expect(
        page,
        contains('<meta property="og:description" content="Description">'),
      );
      expect(
        page,
        contains(
          '<meta property="og:url" '
          'content="https://example.org/en/gym/12">',
        ),
      );
      expect(page, contains('<meta property="og:type" content="website">'));
      expect(
        page,
        contains('<meta property="og:site_name" content="Example">'),
      );
      expect(page, contains('<meta property="og:locale" content="en_US">'));
      expect(
        page,
        contains(
          '<meta property="og:image" content="https://example.org/img/12.jpg">',
        ),
      );
      expect(page, contains('<meta property="og:image:alt" content="Front">'));
      expect(
        page,
        contains('<meta name="twitter:card" content="summary_large_image">'),
      );
    });

    test('social without an image writes summary', () {
      final page = _render(social: const HtmlSocial());
      expect(page, contains('<meta name="twitter:card" content="summary">'));
      expect(page, isNot(contains('og:image')));
    });

    test('og:image on an external CDN is accepted', () {
      expect(
        _render(
          social: const HtmlSocial(image: 'https://cdn.example.net/a.jpg'),
        ),
        contains(
          '<meta property="og:image" content="https://cdn.example.net/a.jpg">',
        ),
      );
    });
  });

  group('body', () {
    test('text with a script is escaped', () {
      final root = Element.tag('p')
        ..append(Text('</script><script>alert(1)</script>'));
      expect(
        _body(root),
        '<p>&lt;/script&gt;&lt;script&gt;alert(1)&lt;/script&gt;</p>',
      );
    });

    test('the body goes at the start of the page <body>', () {
      final page = _render(body: Element.tag('main')..text = 'Hello');
      expect(page, matches(RegExp(r'<body>\s*<main>Hello</main>')));
    });

    test('noscript throws', () {
      expect(
        () => _body(Element.tag('div')..append(Element.tag('noscript'))),
        throwsArgumentError,
      );
    });

    test('svg throws', () {
      expect(
        () => _body(_fragment('<div><svg><circle r="1"></circle></svg></div>')),
        throwsArgumentError,
      );
    });

    test('element from another namespace throws even with an allowed name', () {
      final svg = _fragment('<svg><a href="/x"></a></svg>');
      expect(() => _body(svg.children.first), throwsArgumentError);
    });

    test('onclick throws', () {
      expect(
        () => _body(_fragment('<p onclick="alert(1)">x</p>')),
        throwsArgumentError,
      );
    });

    test('style throws', () {
      expect(
        () => _body(_fragment('<p style="color:red">x</p>')),
        throwsArgumentError,
      );
    });

    test('data-* and aria-* pass', () {
      expect(
        _body(_fragment('<span data-id="12" aria-label="a&quot;b">x</span>')),
        '<span data-id="12" aria-label="a&quot;b">x</span>',
      );
    });

    test('href javascript: is dropped and reported', () {
      final dropped = <String>[];
      expect(
        _body(_fragment('<a href="javascript:alert(1)">x</a>'), dropped),
        '<a>x</a>',
      );
      expect(dropped, ['a href']);
    });

    test('href //other.site is dropped', () {
      expect(_body(_fragment('<a href="//evil.site">x</a>')), '<a>x</a>');
    });

    test('src data: is dropped', () {
      expect(
        _body(_fragment('<img src="data:image/png;base64,AA" alt="x">')),
        '<img alt="x">',
      );
    });

    test('external https href and https src pass', () {
      expect(
        _body(_fragment('<a href="https://site.example.org/?a=1&b=2">x</a>')),
        '<a href="https://site.example.org/?a=1&amp;b=2">x</a>',
      );
      expect(
        _body(_fragment('<img src="https://cdn/x.jpg">')),
        '<img src="https://cdn/x.jpg">',
      );
    });

    test('br and img are written without a closing tag', () {
      expect(
        _body(_fragment('<p>a<br>b<img src="/x.jpg"></p>')),
        '<p>a<br>b<img src="/x.jpg"></p>',
      );
    });

    test('comments are not written', () {
      final root = Element.tag('p')
        ..append(Comment('secret'))
        ..append(Text('x'));
      expect(_body(root), '<p>x</p>');
    });

    test('nesting is preserved', () {
      expect(
        _body(
          _fragment(
            '<article><h1>T</h1><ul><li><a href="/a">A</a></li></ul></article>',
          ),
        ),
        '<article><h1>T</h1><ul><li><a href="/a">A</a></li></ul></article>',
      );
    });
  });

  group('not found', () {
    test('carries noindex, follow', () {
      expect(
        HtmlRender.notFound(_template, const HtmlNotFound()),
        contains('<meta name="robots" content="noindex, follow">'),
      );
    });

    test('title is optional', () {
      expect(
        HtmlRender.notFound(_template, const HtmlNotFound()),
        isNot(contains('<title>')),
      );
      expect(
        HtmlRender.notFound(
          _template,
          const HtmlNotFound(lang: 'de', title: 'Not found'),
        ),
        allOf(contains('<title>Not found</title>'), contains('lang="de"')),
      );
    });

    test('default lang is en', () {
      expect(
        HtmlRender.notFound(_template, const HtmlNotFound()),
        contains('<html lang="en">'),
      );
    });
  });

  group('cache policy', () {
    test('default and none', () {
      expect(
        const HtmlCachePolicy().headerValue,
        'public, max-age=0, s-maxage=300, stale-while-revalidate=86400, '
        'stale-if-error=86400',
      );
      expect(const HtmlCachePolicy.none().headerValue, 'no-store');
    });
  });
}
