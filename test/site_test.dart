import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart' show Element;
import 'package:make_it_crawlable/make_it_crawlable.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const _template =
    '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><base href="/"><title>App</title><meta name="description" content="generic"></head><body><script src="flutter_bootstrap.js" async></script></body></html>';

final _origin = Uri.parse('https://example.org');

/// A response read in full.
typedef _Got = ({int status, HttpHeaders headers, String body});

/// Keeps each event as text, for the assertions.
class _RecordingObserver extends CrawlableObserver {
  final events = <String>[];
  final served = <int>[];

  @override
  void onServed(String path, int status, Duration elapsed) =>
      served.add(status);

  @override
  void onUrlDropped(String tag, String attribute) =>
      events.add('dropped $tag $attribute');

  @override
  void onTemplateRetry(Uri url, int attempt, Object error, StackTrace stack) =>
      events.add('retry $attempt');

  @override
  void onTemplateChanged(String version) => events.add('changed');

  @override
  void onTemplateRejected(Uri url, FormatException error, StackTrace stack) =>
      events.add('rejected');

  @override
  void onTemplateFetchFailed(Uri url, Object error, StackTrace stack) =>
      events.add('fetch failed');

  @override
  void onFailure(CrawlableCall call, Object error, StackTrace stack) =>
      events.add('failure ${call.name}');

  @override
  void onUnexpectedError(String path, Object error, StackTrace stack) =>
      events.add('unexpected $path');

  @override
  void onSitemapIndexTruncated(int files) => events.add('index truncated');

  @override
  void onSitemapTruncated(String source, int bucket, int written) =>
      events.add('truncated $source-$bucket $written');
}

/// An observer whose [onFailure], and optionally [onServed] and
/// [onUnexpectedError], throw.
class _ThrowingObserver extends _RecordingObserver {
  _ThrowingObserver({
    this.onServedThrows = false,
    this.unexpectedThrows = false,
  });

  final bool onServedThrows;
  final bool unexpectedThrows;

  @override
  void onServed(String path, int status, Duration elapsed) {
    super.onServed(path, status, elapsed);
    if (onServedThrows) {
      throw StateError('observer onServed');
    }
  }

  @override
  void onFailure(CrawlableCall call, Object error, StackTrace stack) =>
      throw StateError('observer onFailure');

  @override
  void onUnexpectedError(String path, Object error, StackTrace stack) {
    super.onUnexpectedError(path, error, stack);
    if (unexpectedThrows) {
      throw StateError('observer onUnexpectedError');
    }
  }
}

/// The test around: marks the response with the call name.
Future<Response> _mark(CrawlableCall call, Future<Response> Function() work) {
  call.headers['x-call'] = call.name;
  return work();
}

/// Builds a [CrawlableSite] with the test defaults.
CrawlableSite _site({
  List<HtmlPageRule>? pages,
  List<SitemapSource> sitemaps = const [],
  HtmlTemplateSource template = const HtmlTemplateSource.text(_template),
  RobotsTxt robots = const RobotsTxt(),
  CrawlableAround around = _mark,
  CrawlableObserver? observer,
  Uri? origin,
}) => CrawlableSite(
  origin: origin ?? _origin,
  template: template,
  pages: pages ?? [_gymRule()],
  sitemaps: sitemaps,
  robots: robots,
  around: around,
  observer: observer ?? _RecordingObserver(),
);

/// Starts and serves a site on port 0 and closes it at the end of the test.
Future<CrawlableSite> _serve({
  List<HtmlPageRule>? pages,
  List<SitemapSource> sitemaps = const [],
  HtmlTemplateSource template = const HtmlTemplateSource.text(_template),
  CrawlableAround around = _mark,
  CrawlableObserver? observer,
}) async {
  final site = _site(
    pages: pages,
    sitemaps: sitemaps,
    template: template,
    around: around,
    observer: observer,
  );
  addTearDown(site.close);
  await site.start();
  await site.serve(0, address: InternetAddress.loopbackIPv4);
  return site;
}

/// The events recorded by the observer of [site].
List<String> _events(CrawlableSite site) =>
    (site.observer as _RecordingObserver).events;

/// Requests [path] from [site] with [method] and [headers].
Future<_Got> _call(
  CrawlableSite site,
  String path, {
  String method = 'GET',
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${site.server!.port}$path'),
    );
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    return (status: res.statusCode, headers: res.headers, body: body);
  } finally {
    client.close(force: true);
  }
}

Element _p(String text) =>
    Element.tag('main')..append(Element.tag('p')..text = text);

HtmlPageRule _gymRule({
  void Function(HtmlRequest)? seen,
  HtmlCachePolicy? cache,
  HtmlRobots robots = const HtmlRobots(),
}) => HtmlPageRule(
  route: '/:lang/gym/:id',
  query: const {'b', 'a'},
  resolve: (request) async {
    seen?.call(request);
    return HtmlPage(
      lang: request.params['lang']!,
      title: 'Gym ${request.params['id']}',
      description: 'A gym',
      body: _p('Equipment'),
      cache: cache,
      robots: robots,
      social: const HtmlSocial(),
    );
  },
);

HtmlPageRule _answer(String route, HtmlAnswer answer) =>
    HtmlPageRule(route: route, resolve: (_) async => answer);

final class _Source implements SitemapSource {
  _Source(this.name, this.buckets, {this.perBucket = 2, this.fail = false});

  @override
  final String name;
  final int buckets;
  final int perBucket;
  final bool fail;

  @override
  Future<int> bucketCount() async => buckets;

  @override
  Future<List<SitemapEntry>> entries(int bucket) async {
    if (fail) {
      throw StateError('index down');
    }
    return [
      for (var i = 0; i < perBucket; i++) SitemapEntry('/en/gym/$bucket-$i'),
    ];
  }
}

/// A local server that delivers the app template.
final class _TemplateHost {
  _TemplateHost(this._server);

  final HttpServer _server;
  String html = _template.replaceFirst('App', 'v1');
  int status = 200;
  Duration delay = Duration.zero;
  int requests = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  final List<String?> ifNoneMatch = [];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/index.html');

  static Future<_TemplateHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _TemplateHost(server);
    server.listen(host._handle);
    addTearDown(() => server.close(force: true));
    return host;
  }

  Future<void> _handle(HttpRequest req) async {
    requests++;
    inFlight++;
    if (inFlight > maxInFlight) {
      maxInFlight = inFlight;
    }
    ifNoneMatch.add(req.headers.value('if-none-match'));
    await Future<void>.delayed(delay);
    final etag = '"${html.hashCode}"';
    if (status != 200) {
      req.response.statusCode = status;
    } else if (req.headers.value('if-none-match') == etag) {
      req.response.statusCode = 304;
    } else {
      req.response.headers.set('etag', etag);
      req.response.write(html);
    }
    await req.response.close();
    inFlight--;
  }
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  group('page', () {
    test('200 with page headers', () async {
      final site = await _serve();
      final got = await _call(site, '/en/gym/12');

      expect(got.status, 200);
      expect(got.headers.value('content-type'), 'text/html; charset=utf-8');
      expect(
        got.headers.value('cache-control'),
        'public, max-age=0, s-maxage=300, stale-while-revalidate=86400, '
        'stale-if-error=86400',
      );
      expect(got.headers.value('content-language'), 'en');
      expect(got.headers.value('x-call'), 'HtmlPage /:lang/gym/:id');
      expect(got.headers.value('etag'), matches(RegExp(r'^W/"[0-9a-f]{40}"$')));
      expect(got.headers.value('x-content-type-options'), 'nosniff');
      expect(
        got.headers.value('referrer-policy'),
        'strict-origin-when-cross-origin',
      );
      expect(got.headers.value('x-robots-tag'), isNull);
      expect(got.headers.value('x-powered-by'), isNull);
      expect(got.body, contains('<title>Gym 12</title>'));
      expect(got.body, isNot(contains('<title>App</title>')));
      expect(got.body, contains('<p>Equipment</p>'));
    });

    test('route parameters and declared search reach the rule', () async {
      HtmlRequest? seen;
      final site = await _serve(pages: [_gymRule(seen: (r) => seen = r)]);
      final got = await _call(site, '/en/gym/12?b=2&utm_source=x&a=1');

      expect(seen!.params, {'lang': 'en', 'id': '12'});
      expect(seen!.query, {'a': '1', 'b': '2'});
      expect(seen!.path.toString(), '/en/gym/12?a=1&b=2');
      expect(
        got.body,
        contains(
          '<link rel="canonical" href="https://example.org/en/gym/12?a=1&amp;b=2">',
        ),
      );
      expect(got.body, isNot(contains('utm_source')));
    });

    test('percent-encoded parameter reaches the rule decoded', () async {
      HtmlRequest? seen;
      final site = await _serve(pages: [_gymRule(seen: (r) => seen = r)]);
      await _call(site, '/en/gym/a%20b');

      expect(seen!.params['id'], 'a b');
    });

    test('page cache replaces the default', () async {
      final site = await _serve(
        pages: [_gymRule(cache: const HtmlCachePolicy.none())],
      );
      final got = await _call(site, '/en/gym/12');

      expect(got.headers.value('cache-control'), 'no-store');
    });

    test('robots without index sets x-robots-tag', () async {
      final site = await _serve(
        pages: [_gymRule(robots: const HtmlRobots(index: false))],
      );
      final got = await _call(site, '/en/gym/12');

      expect(got.headers.value('x-robots-tag'), 'noindex');
    });

    test('forged Host changes neither canonical nor og:url', () async {
      final site = await _serve();
      final got = await _call(
        site,
        '/en/gym/12',
        headers: {'host': 'other.site', 'x-forwarded-host': 'other.site'},
      );

      expect(got.body, isNot(contains('other.site')));
      expect(got.body, contains('content="https://example.org/en/gym/12"'));
    });

    test('unsafe URL in the body is dropped and reported', () async {
      final site = await _serve(
        pages: [
          _answer(
            '/link',
            HtmlPage(
              lang: 'en',
              title: 'Link',
              body: Element.tag('main')
                ..append(
                  Element.tag('a')
                    ..attributes['href'] = 'javascript:alert(1)'
                    ..text = 'x',
                ),
            ),
          ),
        ],
      );
      final got = await _call(site, '/link');

      expect(got.status, 200);
      expect(got.body, contains('<main><a>x</a></main>'));
      expect(_events(site), ['dropped a href']);
    });
  });

  group('HTTP', () {
    test('HEAD has the GET headers and an empty body', () async {
      final site = await _serve();
      final get = await _call(site, '/en/gym/12');
      final head = await _call(site, '/en/gym/12', method: 'HEAD');

      expect(head.status, 200);
      expect(head.body, isEmpty);
      expect(head.headers.contentLength, get.headers.contentLength);
      expect(head.headers.contentLength, utf8.encode(get.body).length);
      expect(head.headers.value('etag'), get.headers.value('etag'));
      expect(
        head.headers.value('cache-control'),
        get.headers.value('cache-control'),
      );
    });

    test('If-None-Match with the ETag gives 304 without a body', () async {
      final site = await _serve();
      final first = await _call(site, '/en/gym/12');
      final etag = first.headers.value('etag')!;
      final got = await _call(
        site,
        '/en/gym/12',
        headers: {'if-none-match': 'W/"other", $etag'},
      );

      expect(got.status, 304);
      expect(got.body, isEmpty);
    });

    test('If-None-Match with the ETag without W/ gives 304', () async {
      final site = await _serve();
      final first = await _call(site, '/en/gym/12');
      final strong = first.headers.value('etag')!.substring(2);
      final got = await _call(
        site,
        '/en/gym/12',
        headers: {'if-none-match': strong},
      );

      expect(got.status, 304);
    });

    test('If-None-Match with another ETag gives 200 with a body', () async {
      final site = await _serve();
      final got = await _call(
        site,
        '/en/gym/12',
        headers: {'if-none-match': 'W/"other"'},
      );

      expect(got.status, 200);
      expect(got.body, contains('<title>Gym 12</title>'));
    });

    test('If-None-Match * gives 304', () async {
      final site = await _serve();
      final got = await _call(
        site,
        '/en/gym/12',
        headers: {'if-none-match': '*'},
      );

      expect(got.status, 304);
    });

    test('onServed receives the final status', () async {
      final site = await _serve();
      await _call(site, '/en/gym/12');
      await _call(site, '/en/gym/12', headers: {'if-none-match': '*'});

      expect((site.observer as _RecordingObserver).served, [200, 304]);
    });

    test('trailing slash gives 301 with the original search', () async {
      final site = await _serve();
      final got = await _call(site, '/en/gym/12/?utm_source=x');

      expect(got.status, 301);
      expect(
        got.headers.value('location'),
        'https://example.org/en/gym/12?utm_source=x',
      );
    });

    test('several trailing slashes give one 301 to the clean path', () async {
      final site = await _serve();
      final got = await _call(site, '/en/gym/12//');

      expect(got.status, 301);
      expect(got.headers.value('location'), 'https://example.org/en/gym/12');
    });

    test('a leading double slash gives 301 to the clean path', () async {
      final site = await _serve();
      final got = await _call(site, '//en/gym/12');

      expect(got.status, 301);
      expect(got.headers.value('location'), 'https://example.org/en/gym/12');
    });

    test('uppercase gives 301 to lowercase', () async {
      final site = await _serve();
      final got = await _call(site, '/EN/Gym/12?x=1');

      expect(got.status, 301);
      expect(
        got.headers.value('location'),
        'https://example.org/en/gym/12?x=1',
      );
    });

    test('POST and TRACE on a page give 405', () async {
      final site = await _serve();
      for (final method in ['POST', 'TRACE']) {
        final got = await _call(site, '/en/gym/12', method: method);

        expect(got.status, 405, reason: method);
        expect(got.headers.value('allow'), 'GET, HEAD');
      }
    });

    test('GET / without a rule on / gives the shell', () async {
      final site = await _serve();
      final got = await _call(site, '/');

      expect(got.status, 200);
      expect(got.body, _template);
    });

    test('GET / with a rule on / is served', () async {
      final site = await _serve(
        pages: [_answer('/', const HtmlPage(lang: 'en', title: 'Home'))],
      );
      final got = await _call(site, '/');

      expect(got.status, 200);
      expect(got.body, contains('<title>Home</title>'));
    });
  });

  group('answers', () {
    test('permanent redirect with an absolute location', () async {
      final site = await _serve(
        pages: [_answer('/old', const HtmlRedirect('/en/gym/13'))],
      );
      final got = await _call(site, '/old');

      expect(got.status, 301);
      expect(got.headers.value('location'), 'https://example.org/en/gym/13');
    });

    test('temporary redirect gives 302', () async {
      final site = await _serve(
        pages: [_answer('/old', const HtmlRedirect('/new', permanent: false))],
      );
      final got = await _call(site, '/old');

      expect(got.status, 302);
    });

    test('redirect to another origin gives 500 with the shell', () async {
      final site = await _serve(
        pages: [_answer('/old', const HtmlRedirect('https://other.site/'))],
      );
      final got = await _call(site, '/old');

      expect(got.status, 500);
      expect(got.body, _template);
      expect(got.headers.value('location'), isNull);
    });

    test('not found gives 404 with noindex', () async {
      final site = await _serve(
        pages: [_answer('/gone', const HtmlNotFound())],
      );
      final got = await _call(site, '/gone');

      expect(got.status, 404);
      expect(got.headers.value('x-robots-tag'), 'noindex');
      expect(got.body, contains('<meta name="robots" content="noindex'));
    });

    test('gone gives 410', () async {
      final site = await _serve(
        pages: [_answer('/gone', const HtmlNotFound(gone: true))],
      );
      final got = await _call(site, '/gone');

      expect(got.status, 410);
    });
  });

  group('failures', () {
    test('a rule that throws gives 500 with the shell, without leaking the '
        'exception', () async {
      final site = await _serve(
        pages: [
          HtmlPageRule(
            route: '/broken',
            resolve: (_) async => throw StateError('internal-secret'),
          ),
        ],
      );
      final got = await _call(site, '/broken');

      expect(got.status, 500);
      expect(got.body, _template);
      expect(got.body, isNot(contains('internal-secret')));
      expect(got.headers.value('cache-control'), 'no-store');
      expect(got.headers.value('x-call'), 'HtmlPage /broken');
      expect(_events(site), ['failure HtmlPage /broken']);
    });

    test('a body with a script gives 500 with the shell', () async {
      final site = await _serve(
        pages: [
          _answer(
            '/script',
            HtmlPage(
              lang: 'en',
              title: 'X',
              body: Element.tag('main')..append(Element.tag('script')),
            ),
          ),
        ],
      );
      final got = await _call(site, '/script');

      expect(got.status, 500);
      expect(got.body, _template);
    });

    test('an around that throws before calling work gives 500', () async {
      final site = await _serve(
        around: (call, work) async => throw StateError('around'),
      );
      final got = await _call(site, '/en/gym/12');

      expect(got.status, 500);
      expect(got.body, _template);
      expect(_events(site), ['failure HtmlPage /:lang/gym/:id']);
    });

    test('an around that adds a header after work keeps it', () async {
      final site = await _serve(
        around: (call, work) async =>
            (await work()).change(headers: {'x-after': '1'}),
      );
      final got = await _call(site, '/en/gym/12');

      expect(got.status, 200);
      expect(got.headers.value('x-after'), '1');
      expect(got.headers.contentLength, utf8.encode(got.body).length);
    });

    test('an observer whose onFailure throws still gives 500 with the '
        'shell', () async {
      final site = await _serve(
        pages: [
          HtmlPageRule(
            route: '/broken',
            resolve: (_) async => throw StateError('rule'),
          ),
        ],
        observer: _ThrowingObserver(),
      );
      final got = await _call(site, '/broken');

      expect(got.status, 500);
      expect(got.body, _template);
      expect(_events(site), ['unexpected /broken']);
    });

    test('an observer whose onServed throws does not change the '
        'response', () async {
      final site = _site(observer: _ThrowingObserver(onServedThrows: true));
      addTearDown(site.close);
      await site.start();
      final errors = <Object>[];
      final response = await runZonedGuarded(
        () => site.handler(
          Request('GET', Uri.parse('https://example.org/en/gym/12')),
        ),
        (e, _) => errors.add(e),
      )!;

      expect(response.statusCode, 200);
      expect(await response.readAsString(), contains('<title>Gym 12</title>'));
      expect(errors, [isA<StateError>()]);
    });

    test(
      'an observer whose onUnexpectedError throws still gives 500',
      () async {
        final site = _site(
          pages: [
            HtmlPageRule(
              route: '/broken',
              resolve: (_) async => throw StateError('rule'),
            ),
          ],
          observer: _ThrowingObserver(unexpectedThrows: true),
        );
        addTearDown(site.close);
        await site.start();
        final errors = <Object>[];
        final response = await runZonedGuarded(
          () => site.handler(
            Request('GET', Uri.parse('https://example.org/broken')),
          ),
          (e, _) => errors.add(e),
        )!;

        expect(response.statusCode, 500);
        expect(await response.readAsString(), _template);
        expect(errors, [isA<StateError>()]);
      },
    );
  });

  group('shell', () {
    test('a path without a rule gives the original template with '
        'noindex', () async {
      final site = await _serve();
      final got = await _call(site, '/account/settings');

      expect(got.status, 200);
      expect(got.body, _template);
      expect(got.headers.value('x-robots-tag'), 'noindex');
      expect(
        got.headers.value('cache-control'),
        const HtmlCachePolicy().headerValue,
      );
    });

    test('a path with an extension gives 404 in text', () async {
      final site = await _serve();
      final got = await _call(site, '/main.dart.js');

      expect(got.status, 404);
      expect(got.headers.value('content-type'), 'text/plain; charset=utf-8');
      expect(got.headers.value('cache-control'), 'no-store');
    });

    test('DELETE on a path without a rule gives 405', () async {
      final site = await _serve();
      final got = await _call(site, '/anything', method: 'DELETE');

      expect(got.status, 405);
      expect(got.headers.value('allow'), 'GET, HEAD');
    });
  });

  group('sitemap', () {
    test('index with one file per bucket', () async {
      final site = await _serve(
        sitemaps: [_Source('gyms', 2), _Source('empty', 0)],
      );
      final got = await _call(site, '/sitemap.xml');

      expect(got.status, 200);
      expect(
        got.headers.value('content-type'),
        'application/xml; charset=utf-8',
      );
      expect(
        got.headers.value('cache-control'),
        const HtmlCachePolicy(shared: Duration(days: 1)).headerValue,
      );
      expect(got.headers.value('x-call'), 'Sitemap index');
      expect(RegExp('<loc>').allMatches(got.body), hasLength(2));
      expect(
        got.body,
        contains('<loc>https://example.org/sitemaps/gyms-1.xml</loc>'),
      );
    });

    test('a file carries the bucket entries', () async {
      final site = await _serve(sitemaps: [_Source('gyms', 2)]);
      final got = await _call(site, '/sitemaps/gyms-1.xml');

      expect(got.status, 200);
      expect(got.headers.value('x-call'), 'Sitemap gyms-1');
      expect(got.body, contains('https://example.org/en/gym/1-0'));
      expect(got.body, contains('https://example.org/en/gym/1-1'));
      expect(got.body, isNot(contains('/en/gym/0-0')));
    });

    test('a missing bucket, source or name gives 404', () async {
      final site = await _serve(
        sitemaps: [_Source('gyms', 2), _Source('empty', 0)],
      );
      for (final path in [
        '/sitemaps/gyms-2.xml',
        '/sitemaps/empty-0.xml',
        '/sitemaps/gyms.xml',
        '/sitemaps/other-0.xml',
      ]) {
        final got = await _call(site, path);

        expect(got.status, 404, reason: path);
      }
    });

    test('a path with a slash under /sitemaps/ gives 404 with the notFound '
        'policy', () async {
      final site = await _serve(sitemaps: [_Source('gyms', 2)]);
      final got = await _call(site, '/sitemaps/a/b-0.xml');

      expect(got.status, 404);
      expect(got.body, 'Not found');
      expect(
        got.headers.value('cache-control'),
        const HtmlServerDefaults().notFound.headerValue,
      );
    });

    test('a source that throws gives 500 in text', () async {
      final site = await _serve(sitemaps: [_Source('gyms', 1, fail: true)]);
      final got = await _call(site, '/sitemaps/gyms-0.xml');

      expect(got.status, 500);
      expect(got.headers.value('content-type'), 'text/plain; charset=utf-8');
      expect(got.headers.value('x-call'), 'Sitemap gyms-0');
      expect(got.body, isNot(contains('index down')));
      expect(_events(site), ['failure Sitemap gyms-0']);
    });

    test('a bucket over the limit is cut and reported', () async {
      final site = await _serve(
        sitemaps: [_Source('gyms', 1, perBucket: 50001)],
      );
      final got = await _call(site, '/sitemaps/gyms-0.xml');

      expect(got.status, 200);
      expect(RegExp('<url>').allMatches(got.body), hasLength(50000));
      expect(_events(site), contains('truncated gyms-0 50000'));
    });

    test('without sources, /sitemap.xml gives 404 in text', () async {
      final site = await _serve();
      final got = await _call(site, '/sitemap.xml');

      expect(got.status, 404);
      expect(got.headers.value('content-type'), 'text/plain; charset=utf-8');
    });

    test('a /:lang rule without sources does not take /sitemap.xml', () async {
      final site = await _serve(
        pages: [_answer('/:lang', const HtmlPage(lang: 'en', title: 'Lang'))],
      );
      final got = await _call(site, '/sitemap.xml');

      expect(got.status, 404);
      expect(got.body, 'Not found');
    });
  });

  group('robots', () {
    test('with sources it ends with the sitemap line', () async {
      final site = await _serve(sitemaps: [_Source('gyms', 1)]);
      final got = await _call(site, '/robots.txt');

      expect(got.status, 200);
      expect(
        got.body.trimRight(),
        endsWith('Sitemap: https://example.org/sitemap.xml'),
      );
    });

    test('without sources there is no sitemap line', () async {
      final site = await _serve();
      final got = await _call(site, '/robots.txt');

      expect(got.status, 200);
      expect(got.body, isNot(contains('Sitemap:')));
    });

    test('a /:lang rule does not take /robots.txt or /sitemap.xml', () async {
      final site = await _serve(
        pages: [_answer('/:lang', const HtmlPage(lang: 'en', title: 'Lang'))],
        sitemaps: [_Source('gyms', 1)],
      );
      final robots = await _call(site, '/robots.txt');
      final index = await _call(site, '/sitemap.xml');

      expect(robots.headers.value('content-type'), 'text/plain; charset=utf-8');
      expect(index.headers.value('content-type'), contains('application/xml'));
    });

    test(
      'slashes at the ends of a reserved path still give the file',
      () async {
        final site = await _serve(sitemaps: [_Source('gyms', 1)]);
        final robots = await _call(site, '/robots.txt/');
        final index = await _call(site, '//sitemap.xml');

        expect(robots.status, 200);
        expect(robots.body, startsWith('User-agent: *'));
        expect(index.status, 200);
        expect(
          index.headers.value('content-type'),
          contains('application/xml'),
        );
      },
    );
  });

  group('template from a URL', () {
    Future<CrawlableSite> serveFrom(_TemplateHost host, {int attempts = 5}) =>
        _serve(
          pages: [_answer('/en', const HtmlPage(lang: 'en', title: 'Home'))],
          template: HtmlTemplateSource.url(
            host.url,
            refresh: const Duration(milliseconds: 50),
            attempts: attempts,
            retryDelay: const Duration(milliseconds: 10),
          ),
        );

    test('a version change shows in the shell', () async {
      final host = await _TemplateHost.start();
      final site = await serveFrom(host);

      expect((await _call(site, '/account')).body, contains('v1'));
      host.html = _template.replaceFirst('App', 'v2');
      await _until(() => host.requests >= 3);

      expect((await _call(site, '/account')).body, contains('v2'));
    });

    test('If-None-Match arrives and the 304 changes nothing', () async {
      final host = await _TemplateHost.start();
      final site = await serveFrom(host);
      await _until(() => host.requests >= 3);

      expect(host.ifNoneMatch.first, isNull);
      expect(host.ifNoneMatch.skip(1), everyElement('"${host.html.hashCode}"'));
      expect((await _call(site, '/account')).body, contains('v1'));
    });

    test('a template server at 500 keeps the version and reports', () async {
      final host = await _TemplateHost.start();
      final site = await serveFrom(host);
      host
        ..html = _template.replaceFirst('App', 'v2')
        ..status = 500;
      await _until(() => _events(site).contains('fetch failed'));

      expect((await _call(site, '/account')).body, contains('v1'));
    });

    test('a new template without body keeps the version and reports', () async {
      final host = await _TemplateHost.start();
      final site = await serveFrom(host);
      host.html = '<html><head></head></html>';
      await _until(() => _events(site).contains('rejected'));

      expect((await _call(site, '/account')).body, contains('v1'));
    });

    test('a slow refresh does not overlap', () async {
      final host = await _TemplateHost.start();
      await serveFrom(host);
      host.delay = const Duration(milliseconds: 200);
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(host.maxInFlight, 1);
    });

    test('a template down at startup throws with the cause', () async {
      final host = await _TemplateHost.start();
      host.status = 500;
      final site = _site(
        template: HtmlTemplateSource.url(
          host.url,
          attempts: 2,
          retryDelay: const Duration(milliseconds: 10),
        ),
        pages: const [],
      );
      addTearDown(site.close);

      await expectLater(
        site.start(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('status 500'),
          ),
        ),
      );
      expect(_events(site), ['retry 1']);
    });
  });

  group('startup and shutdown', () {
    Future<void> refuses({
      List<HtmlPageRule> pages = const [],
      List<SitemapSource> sitemaps = const [],
      RobotsTxt robots = const RobotsTxt(),
      Uri? origin,
    }) async {
      final site = _site(
        origin: origin,
        pages: pages,
        sitemaps: sitemaps,
        robots: robots,
      );
      addTearDown(site.close);
      await expectLater(site.start(), throwsStateError);
    }

    const page = HtmlPage(lang: 'en', title: 'X');

    test('an invalid configuration throws StateError', () async {
      await refuses(pages: [_answer('/a', page), _answer('/a', page)]);
      await refuses(pages: [_answer('/robots.txt', page)]);
      await refuses(pages: [_answer('/sitemaps/x', page)]);
      await refuses(pages: [_answer('/Gym', page)]);
      await refuses(origin: Uri.parse('https://example.org/app'));
      await refuses(sitemaps: [_Source('Gyms', 1)]);
      await refuses(sitemaps: [_Source('a', 1), _Source('a', 1)]);
    });

    test('a route with * or a repeated parameter throws StateError', () async {
      await refuses(pages: [_answer('/a/*', page)]);
      await refuses(pages: [_answer('/:id/:id', page)]);
    });

    test('a robots.txt entry with a line break throws StateError', () async {
      await refuses(robots: const RobotsTxt(disallow: ['/a\nAllow: /']));
    });

    test('handler before start throws StateError', () {
      expect(() => _site().handler, throwsStateError);
    });

    test('start twice throws StateError', () async {
      final site = _site();
      addTearDown(site.close);
      await site.start();

      await expectLater(site.start(), throwsStateError);
    });

    test('serve sets the idle timeout to 620 s', () async {
      final site = await _serve();

      expect(site.server!.idleTimeout, const Duration(seconds: 620));
    });

    test('after close the connection is refused', () async {
      final site = _site(pages: const []);
      await site.start();
      final server = await site.serve(0, address: InternetAddress.loopbackIPv4);
      final port = server.port;
      await site.close();

      expect(site.server, isNull);
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, port),
        throwsA(isA<SocketException>()),
      );
    });
  });
}
