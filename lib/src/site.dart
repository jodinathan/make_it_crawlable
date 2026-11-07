import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'call.dart';
import 'observer.dart';
import 'page.dart';
import 'render.dart';
import 'route.dart';
import 'sitemap.dart';
import 'template.dart';

/// A page route. [route] uses the [HtmlRoute] syntax, literal segments and
/// `:name` parameters (`/:lang/gym/:id`), always lowercase; [query] are the
/// only search parameters the page sees and that go into the default
/// canonical URL. [resolve] runs inside `CrawlableSite.around` and returns the
/// page, a redirect or a not-found answer.
final class HtmlPageRule {
  /// A rule for [route], answered by [resolve].
  const HtmlPageRule({
    required this.route,
    required this.resolve,
    this.query = const {},
  });

  /// The route, such as `/:lang/gym/:id`.
  final String route;

  /// Builds the answer for a request that matched [route].
  final Future<HtmlAnswer> Function(HtmlRequest request) resolve;

  /// The search parameters the page sees.
  final Set<String> query;
}

/// What the rule receives: the route parameters, the declared search
/// parameters and the requested path with them, in alphabetical order.
final class HtmlRequest {
  /// A request with its [params], [query] and [path].
  const HtmlRequest({
    required this.params,
    required this.query,
    required this.path,
  });

  /// The route parameters, percent-decoded.
  final Map<String, String> params;

  /// The declared search parameters present in the request.
  final Map<String, String> query;

  /// The requested path with the declared search parameters.
  final Uri path;
}

/// Where the app's `index.html` comes from. [HtmlTemplateSource.text] is
/// fixed; [HtmlTemplateSource.url] is read at startup (up to `attempts` times,
/// with `retryDelay` between them) and read again every `refresh` with
/// `If-None-Match`.
sealed class HtmlTemplateSource {
  const HtmlTemplateSource();

  /// A fixed template.
  const factory HtmlTemplateSource.text(String html) = _TextTemplate;

  /// A template read from [url], such as the `index.html` of the published
  /// Flutter web build.
  const factory HtmlTemplateSource.url(
    Uri url, {
    Duration refresh,
    Duration timeout,
    int attempts,
    Duration retryDelay,
  }) = _UrlTemplate;
}

final class _TextTemplate extends HtmlTemplateSource {
  const _TextTemplate(this.html);

  final String html;
}

final class _UrlTemplate extends HtmlTemplateSource {
  const _UrlTemplate(
    this.url, {
    this.refresh = const Duration(minutes: 1),
    this.timeout = const Duration(seconds: 10),
    this.attempts = 5,
    this.retryDelay = const Duration(seconds: 1),
  });

  final Uri url;
  final Duration refresh;
  final Duration timeout;
  final int attempts;
  final Duration retryDelay;
}

/// Default cache policies: [page] for a page, [notFound] for 404 and 410,
/// [shell] for the app shell of a path with no rule, [sitemap] for the
/// sitemap and robots.txt.
final class HtmlServerDefaults {
  /// The default policies.
  const HtmlServerDefaults({
    this.page = const HtmlCachePolicy(),
    this.notFound = const HtmlCachePolicy(
      shared: Duration(minutes: 1),
      staleWhileRevalidate: Duration(minutes: 1),
    ),
    this.shell = const HtmlCachePolicy(),
    this.sitemap = const HtmlCachePolicy(shared: Duration(days: 1)),
  });

  /// The policy for a page.
  final HtmlCachePolicy page;

  /// The policy for 404 and 410.
  final HtmlCachePolicy notFound;

  /// The policy for the app shell of a path with no rule.
  final HtmlCachePolicy shell;

  /// The policy for the sitemap and robots.txt.
  final HtmlCachePolicy sitemap;
}

/// Crawlable HTML pages, `sitemap.xml` and `robots.txt` in front of a
/// Flutter Web app.
///
/// [origin] is the public origin (`https://example.org`), with no path:
/// every absolute URL comes from it, and the `Host` header is never read.
/// [pages] are the routes with a page; a path with no rule gets the template
/// as the app shell, with `noindex`, and a path whose last segment has a dot
/// gets 404. With [sitemaps], the site serves `/sitemap.xml` and
/// `/sitemaps/<source>-<bucket>.xml`; it always serves `/robots.txt` from
/// [robots]. Only GET and HEAD; a page path with uppercase letters or a
/// trailing slash is redirected to its clean lowercase form. [headers] go
/// into every response. [around] wraps each page and sitemap file;
/// [observer] receives the events.
///
/// Call [start] once, then mount [handler] in a shelf server or call
/// [serve]. [close] stops it.
final class CrawlableSite {
  /// Creates the site. Nothing is checked until [start].
  CrawlableSite({
    required this.origin,
    required this.template,
    required this.pages,
    this.sitemaps = const [],
    this.robots = const RobotsTxt(),
    this.defaults = const HtmlServerDefaults(),
    this.headers = defaultHeaders,
    this.around = _direct,
    this.observer = const LoggingCrawlableObserver(),
  });

  /// The headers every response carries unless [headers] replaces them.
  static const defaultHeaders = {
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'strict-origin-when-cross-origin',
  };

  static const _none = HtmlCachePolicy.none();

  static const _reserved = {'/robots.txt', '/sitemap.xml'};

  /// The public origin, scheme and host only.
  final Uri origin;

  /// Where the app's `index.html` comes from.
  final HtmlTemplateSource template;

  /// The page rules, tried in order.
  final List<HtmlPageRule> pages;

  /// The sitemap sources.
  final List<SitemapSource> sitemaps;

  /// The `robots.txt` content.
  final RobotsTxt robots;

  /// The default cache policies.
  final HtmlServerDefaults defaults;

  /// Headers added to every response.
  final Map<String, String> headers;

  /// Wraps each page and sitemap file.
  final CrawlableAround around;

  /// Receives the events.
  final CrawlableObserver observer;

  final List<(HtmlRoute, HtmlPageRule)> _routes = [];
  HtmlTemplate? _current;
  String? _templateEtag;
  Timer? _timer;
  bool _reloading = false;
  http.Client? _client;
  HttpServer? _server;

  static Future<Response> _direct(
    CrawlableCall call,
    Future<Response> Function() work,
  ) => work();

  /// The server opened by [serve], null before it and after [close].
  HttpServer? get server => _server;

  /// The shelf handler. Throws [StateError] before [start] completes.
  Handler get handler {
    if (_current == null) {
      throw StateError('Call CrawlableSite.start() before using its handler.');
    }
    return _handle;
  }

  /// Checks the configuration and reads the template. Throws [StateError]
  /// for an invalid configuration or a template URL that could not be read,
  /// and [FormatException] for an invalid template.
  Future<void> start() async {
    if (_current != null) {
      throw StateError('CrawlableSite.start() was already called.');
    }
    _check();
    final source = template;
    if (source is _UrlTemplate) {
      _client ??= http.Client();
    }
    _current = await _firstTemplate();
    if (source is _UrlTemplate) {
      _timer = Timer.periodic(source.refresh, (_) => _reload());
    }
  }

  /// Serves [handler] on [port] of [address] (all IPv4 interfaces when
  /// null). [idleTimeout] is how long an idle connection stays open: above
  /// the 600 s of Google's load balancer by default.
  Future<HttpServer> serve(
    int port, {
    Object? address,
    Duration idleTimeout = const Duration(seconds: 620),
  }) async {
    if (_server != null) {
      throw StateError('CrawlableSite.serve() was already called.');
    }
    final server = await shelf_io.serve(
      handler,
      address ?? InternetAddress.anyIPv4,
      port,
      poweredByHeader: null,
    );
    server.idleTimeout = idleTimeout;
    return _server = server;
  }

  /// Stops the template refresh, closes the server without cutting requests
  /// in flight, and releases the HTTP client.
  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await _server?.close();
    _server = null;
    _client?.close();
    _client = null;
  }

  /// Refuses a configuration that would produce wrong URLs or conflicting
  /// routes.
  void _check() {
    _routes.clear();
    if ((origin.scheme != 'http' && origin.scheme != 'https') ||
        origin.host.isEmpty ||
        (origin.path != '' && origin.path != '/') ||
        origin.hasQuery ||
        origin.hasFragment) {
      throw StateError(
        'The site origin "$origin" is invalid. Use only an http or https '
        'scheme and a host, with no path or query (https://example.org).',
      );
    }
    final seen = <String>{};
    for (final rule in pages) {
      final route = rule.route;
      if (!route.startsWith('/') || route != route.toLowerCase()) {
        throw StateError(
          'The page route "$route" is invalid: every route starts with "/" and '
          'is lowercase, because the site redirects paths with uppercase '
          'letters to their lowercase form.',
        );
      }
      if (!seen.add(route)) {
        throw StateError(
          'The page route "$route" is declared more than once. Keep one rule '
          'per route.',
        );
      }
      if (_reserved.contains(route) || route.startsWith('/sitemaps/')) {
        throw StateError(
          'The page route "$route" collides with a route of the site itself '
          '(/robots.txt, /sitemap.xml, /sitemaps/). Choose another path.',
        );
      }
      _routes.add((HtmlRoute.parse(route), rule));
    }
    final names = <String>{};
    for (final source in sitemaps) {
      SitemapXml.checkName(source.name);
      if (!names.add(source.name)) {
        throw StateError(
          'The sitemap source "${source.name}" is declared more than once. '
          'Each source needs a unique name, because it names the files.',
        );
      }
    }
    for (final path in robots.disallow) {
      if (path.contains('\n') || path.contains('\r')) {
        throw StateError(
          'The robots.txt disallow entry "${path.replaceAll('\n', r'\n')}" has '
          'a line break, which would add directives to the file. Use one '
          'path per entry.',
        );
      }
    }
  }

  /// The startup template: the fixed text, or the URL read with retries.
  Future<HtmlTemplate> _firstTemplate() async {
    final source = template;
    switch (source) {
      case _TextTemplate():
        return HtmlTemplate.parse(source.html);
      case _UrlTemplate():
        for (var i = 1; ; i++) {
          try {
            final fetched = (await _fetch(source))!;
            final parsed = HtmlTemplate.parse(fetched.body);
            _templateEtag = fetched.etag;
            return parsed;
          } on FormatException {
            rethrow;
          } catch (e, st) {
            if (i >= source.attempts) {
              Error.throwWithStackTrace(
                StateError(
                  'The page template could not be read from ${source.url} '
                  'after ${source.attempts} attempts; the last one failed '
                  'with: $e. Check that the Flutter web build is published at '
                  'that address and reachable from the server.',
                ),
                st,
              );
            }
            observer.onTemplateRetry(source.url, i, e, st);
            await Future<void>.delayed(source.retryDelay);
          }
        }
    }
  }

  /// Reads the template from [source]. Returns null when the server answers
  /// 304 to [etag].
  Future<({String body, String? etag})?> _fetch(
    _UrlTemplate source, {
    String? etag,
  }) async {
    final response = await _client!
        .get(source.url, headers: {'if-none-match': ?etag})
        .timeout(source.timeout);
    if (response.statusCode == 304) {
      return null;
    }
    if (response.statusCode != 200) {
      throw HttpException('status ${response.statusCode}', uri: source.url);
    }
    return (
      body: utf8.decode(response.bodyBytes),
      etag: response.headers['etag'],
    );
  }

  /// Reads the URL template again; a failure keeps the version in use.
  Future<void> _reload() async {
    if (_reloading) {
      return;
    }
    _reloading = true;
    final source = template as _UrlTemplate;
    try {
      final fetched = await _fetch(source, etag: _templateEtag);
      if (fetched == null) {
        return;
      }
      final next = HtmlTemplate.parse(fetched.body);
      _templateEtag = fetched.etag;
      if (next.version != _current?.version) {
        _current = next;
        observer.onTemplateChanged(next.version);
      }
    } on FormatException catch (e, st) {
      observer.onTemplateRejected(source.url, e, st);
    } catch (e, st) {
      observer.onTemplateFetchFailed(source.url, e, st);
    } finally {
      _reloading = false;
    }
  }

  Future<Response> _handle(Request request) async {
    final watch = Stopwatch()..start();
    final path = request.requestedUri.path;
    Response response;
    try {
      response = await _dispatch(request);
    } catch (e, st) {
      _notify(() => observer.onUnexpectedError(path, e, st));
      response = _respond(
        request,
        _Reply.html(500, _current!.source, _none, noindex: true),
      );
    }
    _notify(() => observer.onServed(path, response.statusCode, watch.elapsed));
    return response;
  }

  /// Runs [event] on the observer; an exception from it goes to the current
  /// zone's uncaught-error handler and the response is still served.
  static void _notify(void Function() event) {
    try {
      event();
    } catch (e, st) {
      Zone.current.handleUncaughtError(e, st);
    }
  }

  Future<Response> _dispatch(Request request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      return _respond(request, _Reply.methodNotAllowed());
    }
    final path = request.requestedUri.path;
    final lower = '/${_trimSlashes(path)}'.toLowerCase();
    if (lower == '/robots.txt') {
      return _respond(
        request,
        _Reply.text(
          200,
          robots.text(origin, sitemap: sitemaps.isNotEmpty),
          defaults.sitemap,
        ),
      );
    }
    if (lower == '/sitemap.xml' || lower.startsWith('/sitemaps/')) {
      if (sitemaps.isEmpty) {
        return _respond(request, _Reply.text(404, 'Not found', _none));
      }
      return lower == '/sitemap.xml'
          ? _sitemapIndex(request)
          : _sitemapFile(
              request,
              _trimSlashes(path).substring('sitemaps/'.length),
            );
    }
    for (final (route, rule) in _routes) {
      final params = route.match(path);
      if (params != null) {
        return _page(request, rule, params);
      }
    }
    final last = request.requestedUri.pathSegments.lastOrNull ?? '';
    if (last.contains('.')) {
      return _respond(request, _Reply.text(404, 'Not found', _none));
    }
    return _respond(
      request,
      _Reply.html(200, _current!.source, defaults.shell, noindex: true),
    );
  }

  /// [path] without the slashes at either end, as the page routes match it.
  static String _trimSlashes(String path) {
    var start = 0;
    var end = path.length;
    while (start < end && path.codeUnitAt(start) == 0x2F) {
      start++;
    }
    while (end > start && path.codeUnitAt(end - 1) == 0x2F) {
      end--;
    }
    return path.substring(start, end);
  }

  Future<Response> _page(
    Request request,
    HtmlPageRule rule,
    Map<String, String> params,
  ) async {
    final template = _current!;
    final uri = request.requestedUri;
    final path = uri.path;
    final clean = '/${_trimSlashes(path.toLowerCase())}';
    if (clean != path) {
      final target = origin.replace(
        path: clean,
        query: uri.hasQuery ? uri.query : null,
      );
      return _respond(request, _Reply.redirect(301, target, defaults.page));
    }
    final keys =
        rule.query.where((k) => uri.queryParameters[k] != null).toList()
          ..sort();
    final query = {for (final k in keys) k: uri.queryParameters[k]!};
    final requested = Uri(
      path: path,
      queryParameters: query.isEmpty ? null : query,
    );
    final call = CrawlableCall('HtmlPage ${rule.route}', requested)
      ..attributes['path'] = '$requested';
    return _run(request, call, () async {
      final answer = await rule.resolve(
        HtmlRequest(params: params, query: query, path: requested),
      );
      return _respond(request, _replyFor(template, answer, requested));
    }, () => _Reply.html(500, template.source, _none, noindex: true));
  }

  Future<Response> _run(
    Request request,
    CrawlableCall call,
    Future<Response> Function() work,
    _Reply Function() failure,
  ) async {
    Response response;
    try {
      response = await around(call, work);
    } catch (e, st) {
      observer.onFailure(call, e, st);
      response = _respond(request, failure());
    }
    return call.headers.isEmpty
        ? response
        : response.change(headers: call.headers);
  }

  /// The HTTP reply for each shape of [answer].
  _Reply _replyFor(HtmlTemplate template, HtmlAnswer answer, Uri requested) =>
      switch (answer) {
        HtmlPage() => _Reply.html(
          200,
          HtmlRender.page(
            template,
            answer,
            origin: origin,
            requested: requested,
            onUrlDropped: observer.onUrlDropped,
          ),
          answer.cache ?? defaults.page,
          lang: answer.lang,
          noindex: !answer.robots.index,
        ),
        HtmlRedirect() => _Reply.redirect(
          answer.permanent ? 301 : 302,
          HtmlRender.resolve(origin, answer.location),
          defaults.page,
        ),
        HtmlNotFound() => _Reply.html(
          answer.gone ? 410 : 404,
          HtmlRender.notFound(template, answer),
          answer.cache ?? defaults.notFound,
          lang: answer.lang,
          noindex: true,
        ),
      };

  Future<Response> _sitemapIndex(Request request) {
    final call = CrawlableCall('Sitemap index', Uri(path: '/sitemap.xml'));
    return _run(request, call, () async {
      final files = <SitemapFile>[];
      for (final source in sitemaps) {
        final count = await source.bucketCount();
        for (var k = 0; k < count; k++) {
          files.add((source: source.name, bucket: k));
        }
      }
      final index = SitemapXml.index(origin, files);
      call.attributes
        ..['sources'] = sitemaps.length
        ..['files'] = files.length
        ..['truncated'] = index.truncated;
      if (index.truncated) {
        observer.onSitemapIndexTruncated(files.length);
      }
      return _respond(request, _Reply.xml(index.xml, defaults.sitemap));
    }, () => _Reply.text(500, 'Sitemap unavailable', _none));
  }

  Future<Response> _sitemapFile(Request request, String name) async {
    final notFound = _Reply.text(404, 'Not found', defaults.notFound);
    final file = SitemapXml.parseFileName(name);
    final source = file == null
        ? null
        : sitemaps.where((s) => s.name == file.source).firstOrNull;
    if (file == null || source == null) {
      return _respond(request, notFound);
    }
    final call =
        CrawlableCall(
            'Sitemap ${file.source}-${file.bucket}',
            Uri(path: '/sitemaps/$name'),
          )
          ..attributes['source'] = file.source
          ..attributes['bucket'] = file.bucket;
    return _run(request, call, () async {
      final count = await source.bucketCount();
      if (file.bucket >= count) {
        return _respond(request, notFound);
      }
      final entries = await source.entries(file.bucket);
      final urlset = SitemapXml.urlset(origin, entries);
      call.attributes
        ..['written'] = urlset.written
        ..['truncated'] = urlset.truncated;
      if (urlset.truncated) {
        observer.onSitemapTruncated(file.source, file.bucket, urlset.written);
      }
      return _respond(request, _Reply.xml(urlset.xml, defaults.sitemap));
    }, () => _Reply.text(500, 'Sitemap unavailable', _none));
  }

  /// [reply] as a shelf response, with an ETag and 304 for a 200.
  Response _respond(Request request, _Reply reply) {
    final bytes = utf8.encode(reply.body);
    final out = <String, String>{
      'content-type': reply.contentType,
      'cache-control': reply.policy.headerValue,
      ...headers,
      'content-language': ?reply.lang,
      if (reply.noindex) 'x-robots-tag': 'noindex',
      if (reply.location case final location?) 'location': '$location',
      if (reply.status == 405) 'allow': 'GET, HEAD',
    };
    var status = reply.status;
    List<int> body = bytes;
    if (status == 200) {
      final etag = 'W/"${sha1.convert(bytes)}"';
      out['etag'] = etag;
      if (_matches(request.headers['if-none-match'], etag)) {
        status = 304;
        body = Uint8List(0);
      }
    }
    return Response(status, body: body, headers: out);
  }

  /// Whether the `If-None-Match` [header] covers [etag], by weak comparison
  /// (RFC 9110, section 13.1.2).
  static bool _matches(String? header, String etag) {
    if (header == null) {
      return false;
    }
    final opaque = _opaque(etag);
    return header
        .split(',')
        .map((v) => v.trim())
        .any((v) => v == '*' || _opaque(v) == opaque);
  }

  static String _opaque(String tag) =>
      tag.startsWith('W/') ? tag.substring(2) : tag;
}

/// A response ready for [CrawlableSite._respond].
final class _Reply {
  _Reply.html(
    this.status,
    this.body,
    this.policy, {
    this.lang,
    this.noindex = false,
  }) : contentType = 'text/html; charset=utf-8',
       location = null;

  _Reply.redirect(this.status, Uri this.location, this.policy)
    : body = '',
      contentType = 'text/plain; charset=utf-8',
      lang = null,
      noindex = false;

  _Reply.xml(this.body, this.policy)
    : status = 200,
      contentType = 'application/xml; charset=utf-8',
      lang = null,
      noindex = false,
      location = null;

  _Reply.text(this.status, this.body, this.policy)
    : contentType = 'text/plain; charset=utf-8',
      lang = null,
      noindex = false,
      location = null;

  _Reply.methodNotAllowed()
    : status = 405,
      body = '',
      policy = const HtmlCachePolicy.none(),
      contentType = 'text/plain; charset=utf-8',
      lang = null,
      noindex = false,
      location = null;

  final int status;
  final String body;
  final String contentType;
  final HtmlCachePolicy policy;
  final String? lang;
  final bool noindex;
  final Uri? location;
}
