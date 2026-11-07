import 'dart:convert';

import 'package:make_it_crawlable/src/sitemap.dart';
import 'package:test/test.dart';

void main() {
  final origin = Uri.parse('https://example.org');

  group('SitemapXml.index', () {
    test('lists the files in the given order', () {
      final out = SitemapXml.index(origin, [
        (source: 'equipment-types', bucket: 1),
        (source: 'gyms', bucket: 0),
      ]);

      final first = out.xml.indexOf('equipment-types-1.xml');
      final second = out.xml.indexOf('gyms-0.xml');
      expect(first, greaterThan(0));
      expect(second, greaterThan(first));
      expect(out.truncated, isFalse);
    });

    test('loc is absolute on the origin', () {
      final out = SitemapXml.index(origin, [(source: 'gyms', bucket: 3)]);

      expect(
        out.xml,
        contains(
          '<sitemap><loc>https://example.org/sitemaps/gyms-3.xml</loc>'
          '</sitemap>',
        ),
      );
    });

    test('empty list gives a valid index without <sitemap>', () {
      const ns = 'http://www.sitemaps.org/schemas/sitemap/0.9';
      final out = SitemapXml.index(origin, const []);

      expect(
        out.xml,
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<sitemapindex xmlns="$ns"></sitemapindex>',
      );
      expect(out.truncated, isFalse);
    });

    test('50,001 files give 50,000 and truncated', () {
      final files = [
        for (var i = 0; i <= SitemapXml.maxUrls; i++)
          (source: 'gyms', bucket: i),
      ];

      final out = SitemapXml.index(origin, files);

      expect('<sitemap>'.allMatches(out.xml).length, SitemapXml.maxUrls);
      expect(out.xml, contains('gyms-49999.xml'));
      expect(out.xml, isNot(contains('gyms-50000.xml')));
      expect(out.truncated, isTrue);
    });
  });

  group('SitemapXml.urlset', () {
    test('loc resolved against the origin', () {
      final out = SitemapXml.urlset(origin, const [SitemapEntry('/en/gym/12')]);

      expect(
        out.xml,
        contains('<url><loc>https://example.org/en/gym/12</loc></url>'),
      );
      expect(out.written, 1);
      expect(out.truncated, isFalse);
    });

    test('empty bucket gives a valid urlset without <url>', () {
      final out = SitemapXml.urlset(origin, const []);

      expect(out.xml, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(out.xml, contains('xmlns:xhtml="http://www.w3.org/1999/xhtml"'));
      expect(out.xml, endsWith('</urlset>'));
      expect(out.xml, isNot(contains('<url>')));
      expect(out.written, 0);
    });

    test('lastmod in UTC without fractional seconds', () {
      final at = DateTime.parse('2026-11-06T09:00:00.987-03:00');

      final out = SitemapXml.urlset(origin, [
        SitemapEntry('/en/gym/12', lastModified: at),
      ]);

      expect(out.xml, contains('<lastmod>2026-11-06T12:00:00Z</lastmod>'));
    });

    test('no lastmod when null', () {
      final out = SitemapXml.urlset(origin, const [SitemapEntry('/en/gym/12')]);

      expect(out.xml, isNot(contains('<lastmod>')));
    });

    test('xhtml:link with x-default', () {
      final out = SitemapXml.urlset(origin, const [
        SitemapEntry(
          '/en/gym/12',
          alternates: [
            SitemapAlternate('en-US', '/en/gym/12'),
            SitemapAlternate('pt', '/pt/academia/12'),
            SitemapAlternate('x-default', '/gym/12'),
          ],
        ),
      ]);

      expect(
        out.xml,
        contains(
          '<xhtml:link rel="alternate" hreflang="en-US" '
          'href="https://example.org/en/gym/12"/>',
        ),
      );
      expect(
        out.xml,
        contains(
          '<xhtml:link rel="alternate" hreflang="x-default" '
          'href="https://example.org/gym/12"/>',
        ),
      );
    });

    test('invalid hreflang throws ArgumentError', () {
      expect(
        () => SitemapXml.urlset(origin, [
          SitemapEntry(
            '/en/gym/1',
            alternates: [SitemapAlternate('en"><x', '/en/gym/1')],
          ),
        ]),
        throwsArgumentError,
      );
    });

    test('x-default is accepted', () {
      final xml = SitemapXml.urlset(origin, [
        SitemapEntry(
          '/en/gym/1',
          alternates: [SitemapAlternate('x-default', '/en/gym/1')],
        ),
      ]).xml;
      expect(xml, contains('hreflang="x-default"'));
    });

    test("path with & and ' is escaped", () {
      final out = SitemapXml.urlset(origin, const [
        SitemapEntry("/en/a&b/o'clock"),
      ]);

      expect(
        out.xml,
        contains('<loc>https://example.org/en/a&amp;b/o&apos;clock</loc>'),
      );
    });

    test('path with < is written as %3C', () {
      final out = SitemapXml.urlset(origin, const [SitemapEntry('/en/a<b>')]);

      expect(out.xml, contains('<loc>https://example.org/en/a%3Cb%3E</loc>'));
    });

    test('path with an accent is percent-encoded', () {
      final out = SitemapXml.urlset(origin, const [
        SitemapEntry('/en/city/são-paulo'),
      ]);

      expect(
        out.xml,
        contains('<loc>https://example.org/en/city/s%C3%A3o-paulo</loc>'),
      );
    });

    test('entry on another origin throws ArgumentError', () {
      expect(
        () => SitemapXml.urlset(origin, const [
          SitemapEntry('https://other.example.org/en/gym/12'),
        ]),
        throwsArgumentError,
      );
      expect(
        () => SitemapXml.urlset(origin, const [
          SitemapEntry('//other.example.org/x'),
        ]),
        throwsArgumentError,
      );
      expect(
        () => SitemapXml.urlset(origin, const [
          SitemapEntry(
            '/en/gym/12',
            alternates: [SitemapAlternate('pt', 'http://example.org/pt')],
          ),
        ]),
        throwsArgumentError,
      );
    });

    test('50,001 entries stop at 50,000 with truncated', () {
      final entries = [
        for (var i = 0; i <= SitemapXml.maxUrls; i++) SitemapEntry('/a/$i'),
      ];

      final out = SitemapXml.urlset(origin, entries);

      expect(out.written, SitemapXml.maxUrls);
      expect('<url>'.allMatches(out.xml).length, SitemapXml.maxUrls);
      expect(out.xml, isNot(contains('/a/50000<')));
      expect(out.truncated, isTrue);
    });

    test('large entries stop before 52,428,800 bytes', () {
      final long = '/${'a' * 10000}';
      final entries = [for (var i = 0; i < 6000; i++) SitemapEntry('$long/$i')];

      final out = SitemapXml.urlset(origin, entries);

      expect(
        utf8.encode(out.xml).length,
        lessThanOrEqualTo(SitemapXml.maxBytes),
      );
      expect(out.written, lessThan(entries.length));
      expect(out.written, greaterThan(0));
      expect(out.xml, endsWith('</urlset>'));
      expect(out.truncated, isTrue);
    });
  });

  group('SitemapXml: names', () {
    test('checkName accepts gyms and equipment-types', () {
      SitemapXml.checkName('gyms');
      SitemapXml.checkName('equipment-types');
    });

    test('checkName refuses Gyms, -x, x- and x_y', () {
      for (final name in ['Gyms', '-x', 'x-', 'x_y']) {
        expect(
          () => SitemapXml.checkName(name),
          throwsStateError,
          reason: name,
        );
      }
    });

    test('fileName joins source and bucket', () {
      expect(
        SitemapXml.fileName((source: 'equipment-types', bucket: 2)),
        'equipment-types-2.xml',
      );
    });

    test('parseFileName reads source and bucket', () {
      expect(SitemapXml.parseFileName('gyms-3.xml'), (
        source: 'gyms',
        bucket: 3,
      ));
      expect(SitemapXml.parseFileName('equipment-types-12.xml'), (
        source: 'equipment-types',
        bucket: 12,
      ));
    });

    test('parseFileName returns null outside the shape', () {
      for (final name in [
        'gyms.xml',
        '../x-1.xml',
        'Gyms-1.xml',
        'gyms-01.xml',
      ]) {
        expect(SitemapXml.parseFileName(name), isNull, reason: name);
      }
    });
  });

  group('RobotsTxt', () {
    test('no disallow allows everything', () {
      expect(
        const RobotsTxt().text(origin, sitemap: false),
        'User-agent: *\nAllow: /\n',
      );
    });

    test('with two disallow entries', () {
      expect(
        const RobotsTxt(
          disallow: ['/account', '/search'],
        ).text(origin, sitemap: false),
        'User-agent: *\nDisallow: /account\nDisallow: /search\n',
      );
    });

    test('Sitemap line only with sitemap: true', () {
      expect(
        const RobotsTxt().text(origin, sitemap: true),
        'User-agent: *\nAllow: /\n\nSitemap: https://example.org/sitemap.xml\n',
      );
      expect(
        const RobotsTxt().text(origin, sitemap: false),
        isNot(contains('Sitemap:')),
      );
    });
  });
}
