import 'dart:convert';

import 'render.dart' show HtmlRender;

/// A family of sitemap pages, split into buckets.
///
/// [name] names the files (`gyms` → `/sitemaps/gyms-0.xml`): lowercase
/// letters, digits and hyphens, with no hyphen at either end. [bucketCount]
/// says how many buckets exist now, and [entries] returns the pages of bucket
/// `bucket`, from `0` to `bucketCount() - 1`. Each bucket must fit in
/// [SitemapXml.maxUrls] entries: the product picks the number of buckets for
/// that. Both calls run inside `CrawlableSite.around`.
abstract interface class SitemapSource {
  /// The source name, which names its files.
  String get name;

  /// How many buckets exist now.
  Future<int> bucketCount();

  /// The pages of [bucket].
  Future<List<SitemapEntry>> entries(int bucket);
}

/// A page in the sitemap. [path] is a path on the site's origin
/// (`/en/gym/12`); [lastModified] should only be given when it is the real
/// date of the page's last visible change, because Google ignores `lastmod`
/// on sites where it does not match. [alternates] lists every language
/// version, including the page itself.
final class SitemapEntry {
  /// The page at [path].
  const SitemapEntry(
    this.path, {
    this.lastModified,
    this.alternates = const [],
  });

  /// A path on the site's origin.
  final String path;

  /// The date of the page's last visible change.
  final DateTime? lastModified;

  /// Every language version of the page, including itself.
  final List<SitemapAlternate> alternates;
}

/// The version of an entry in another language: [hreflang] is a BCP 47 tag or
/// `x-default`, [path] a path on the same origin.
final class SitemapAlternate {
  /// The version in [hreflang] at [path].
  const SitemapAlternate(this.hreflang, this.path);

  /// A BCP 47 tag or `x-default`.
  final String hreflang;

  /// A path on the same origin.
  final String path;
}

/// A file of the index: the source and the bucket.
typedef SitemapFile = ({String source, int bucket});

/// Writes the sitemap index and files.
abstract final class SitemapXml {
  /// The protocol's limit of URLs per file and of files per index.
  static const maxUrls = 50000;

  /// The protocol's limit of uncompressed bytes per file.
  static const maxBytes = 52428800;

  static final _name = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');
  static final _file = RegExp(
    r'^([a-z0-9]+(?:-[a-z0-9]+)*)-(0|[1-9]\d{0,8})\.xml$',
  );

  /// Throws [StateError] for a name outside `^[a-z0-9]+(-[a-z0-9]+)*$`: the
  /// site checks it at startup.
  static void checkName(String name) {
    if (!_name.hasMatch(name)) {
      throw StateError(
        'Invalid sitemap source name "$name": use lowercase letters, digits '
        'and hyphens (gyms, equipment-types). The name becomes the file '
        '/sitemaps/<name>-<bucket>.xml.',
      );
    }
  }

  /// The file name of [file], such as `gyms-3.xml`.
  static String fileName(SitemapFile file) =>
      '${file.source}-${file.bucket}.xml';

  /// The file of [name] (`gyms-3.xml`), or null when the name does not have
  /// the shape `<source>-<bucket>.xml`. The bucket is the number after the
  /// last hyphen.
  static SitemapFile? parseFileName(String name) {
    final m = _file.firstMatch(name);
    if (m == null) {
      return null;
    }
    final bucket = int.tryParse(m.group(2)!);
    if (bucket == null) {
      return null;
    }
    return (source: m.group(1)!, bucket: bucket);
  }

  /// The index with one `<sitemap>` per file, in the order of [files], cut at
  /// [maxUrls] files.
  static ({String xml, bool truncated}) index(
    Uri origin,
    List<SitemapFile> files,
  ) {
    final out = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8"?>\n')
      ..write(
        '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
      );
    final kept = files.take(maxUrls);
    for (final f in kept) {
      final loc = origin.replace(path: '/sitemaps/${fileName(f)}');
      out.write('<sitemap><loc>${_esc('$loc')}</loc></sitemap>');
    }
    out.write('</sitemapindex>');
    return (xml: '$out', truncated: files.length > maxUrls);
  }

  /// The `<urlset>` of [entries], stopping before it goes over [maxUrls]
  /// entries or [maxBytes] bytes. [written] is how many went in. A URL on
  /// another origin or an invalid `hreflang` throws [ArgumentError].
  static ({String xml, int written, bool truncated}) urlset(
    Uri origin,
    Iterable<SitemapEntry> entries,
  ) {
    const open =
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
        'xmlns:xhtml="http://www.w3.org/1999/xhtml">';
    const close = '</urlset>';
    final out = StringBuffer(open);
    var bytes = utf8.encode(open).length + utf8.encode(close).length;
    var written = 0;
    var truncated = false;

    for (final e in entries) {
      final item = _url(origin, e);
      final size = utf8.encode(item).length;
      if (written == maxUrls || bytes + size > maxBytes) {
        truncated = true;
        break;
      }
      out.write(item);
      bytes += size;
      written++;
    }
    out.write(close);
    return (xml: '$out', written: written, truncated: truncated);
  }

  static String _url(Uri origin, SitemapEntry e) {
    final out = StringBuffer(
      '<url><loc>${_esc('${_resolve(origin, e.path)}')}</loc>',
    );
    if (e.lastModified case final at?) {
      out.write('<lastmod>${_date(at)}</lastmod>');
    }
    for (final alt in e.alternates) {
      if (alt.hreflang != 'x-default') {
        HtmlRender.checkLang(alt.hreflang);
      }
      out.write(
        '<xhtml:link rel="alternate" hreflang="${_esc(alt.hreflang)}" '
        'href="${_esc('${_resolve(origin, alt.path)}')}"/>',
      );
    }
    out.write('</url>');
    return '$out';
  }

  static Uri _resolve(Uri origin, String path) {
    final uri = origin.resolve(path);
    if (uri.scheme == origin.scheme &&
        uri.host == origin.host &&
        uri.port == origin.port) {
      return uri;
    }
    throw ArgumentError(
      'The sitemap entry "$path" is not on the origin $origin: a sitemap only '
      'lists pages of this site. Use a path such as /en/gym/12.',
    );
  }

  static String _date(DateTime at) {
    final u = at.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
        'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
  }

  static String _esc(String v) => v
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

/// The `robots.txt`: one `User-agent: *` block, with one `Disallow:` line per
/// item of [disallow] (or `Allow: /` with no items), and the `Sitemap:` line
/// when the site has sources.
final class RobotsTxt {
  /// A `robots.txt` that disallows [disallow].
  const RobotsTxt({this.disallow = const []});

  /// The paths crawlers should not visit.
  final List<String> disallow;

  /// The file's text for [origin], with the `Sitemap:` line when [sitemap].
  String text(Uri origin, {required bool sitemap}) {
    final out = StringBuffer('User-agent: *\n');
    if (disallow.isEmpty) {
      out.write('Allow: /\n');
    } else {
      for (final path in disallow) {
        out.write('Disallow: $path\n');
      }
    }
    if (sitemap) {
      out.write('\nSitemap: ${origin.replace(path: '/sitemap.xml')}\n');
    }
    return '$out';
  }
}
