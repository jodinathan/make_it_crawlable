# make_it_crawlable

SEO for Flutter Web. Same HTML for people and bots — no bot detection, no
prerender.

## Why

A Flutter Web app draws on a canvas. Without help, a search engine crawler
gets an empty `index.html` with no text and no links. The Flutter team closed
[flutter/flutter#187663](https://github.com/flutter/flutter/issues/187663)
(October 29, 2026) saying that SEO is out of scope for Flutter Web, and pointed
to serving HTML first with Flutter on top. Dynamic rendering, which detects the
crawler by its User-Agent and serves it something else, is what Google calls a
workaround.

`make_it_crawlable` serves that HTML first.

## How it works

The site reads the `index.html` of your Flutter web build, removes the head
tags that a page writes on its own (title, description, canonical URL, Open
Graph…), and injects the head and the body of the page for the requested path.
The browser shows that HTML, then Flutter starts on top of it as usual. Every
visitor, person or crawler, gets the same response, so a CDN can cache it.

Next to the pages, the site serves `/sitemap.xml`, the sitemap files and
`/robots.txt`.

## The one rule

**The body must show what the app shows.** A body that differs from the
screen is cloaking, and Google penalizes it. Write the same title, text and
links that the app draws for that path.

A second rule follows from caching: the response depends only on the path and
on the search parameters the rule declares. Never on a header (`Host`,
`Accept-Language`, `User-Agent`, cookies): the CDN keeps the first version it
sees and serves it to everyone. The language comes from the path (`/:lang/…`).

## Quick start

```sh
dart pub add make_it_crawlable html
```

```dart
import 'package:html/dom.dart';
import 'package:make_it_crawlable/make_it_crawlable.dart';

Future<void> main() async {
  final site = CrawlableSite(
    origin: Uri.parse('https://example.org'),
    template: HtmlTemplateSource.url(
      Uri.parse('https://storage.example.org/web/index.html'),
    ),
    pages: [
      HtmlPageRule(
        route: '/:lang/gym/:id',
        resolve: (request) async {
          final gym = await findGym(request.params['id']!);
          if (gym == null) {
            return const HtmlNotFound();
          }
          return HtmlPage(
            lang: request.params['lang']!,
            title: gym.name,
            description: gym.summary,
            body: Element.tag('main')
              ..append(Element.tag('h1')..text = gym.name),
          );
        },
      ),
    ],
  );
  await site.start();
  await site.serve(8080);
}
```

The full runnable version is in [example/main.dart](example/main.dart).

## Pages

A rule returns an `HtmlAnswer`: an `HtmlPage`, an `HtmlRedirect` or an
`HtmlNotFound`.

| `HtmlPage` field | Type | Becomes |
|---|---|---|
| `lang` | `String`, required | `lang` of `<html>` and `content-language`. A BCP 47 tag (`en`, `pt-BR`); anything else throws `ArgumentError` |
| `title` | `String`, required | `<title>` and `og:title`. Empty throws `ArgumentError` |
| `description` | `String?` | `<meta name="description">` and `og:description` |
| `canonical` | `String?` | `<link rel="canonical">` and `og:url`. Without it: the origin with the requested path and the declared search parameters in alphabetical order |
| `alternates` | `List<HtmlAlternate>` | One `<link rel="alternate" hreflang>` per item. `hreflang` is a BCP 47 tag or `x-default` |
| `robots` | `HtmlRobots` (default `index` and `follow`) | `<meta name="robots">` only when one of them is false; `index: false` also sends `x-robots-tag: noindex` |
| `social` | `HtmlSocial?` | `og:title`, `og:description`, `og:url`, `og:type` (default `website`), `og:site_name`, `og:locale` (`en_US`), `og:image`, `og:image:alt` and `twitter:card` (`summary_large_image` with an image, `summary` without) |
| `body` | `Element?` | Goes at the start of the template's `<body>` |
| `cache` | `HtmlCachePolicy?` | Replaces `HtmlServerDefaults.page` |

URLs (`canonical`, `HtmlAlternate.href`, redirects, sitemap entries) are paths
(`/en/gym/12`) or absolute URLs **on the same origin**; another origin throws
`ArgumentError`. Only `HtmlSocial.image` accepts any `http`/`https` URL, for an
image on a file CDN.

The other answers:

- `HtmlRedirect(location, permanent: true)`: 301, or 302 with
  `permanent: false`, to a path on the same origin.
- `HtmlNotFound(gone: false, lang:, title:, cache:)`: 404, or 410 with
  `gone: true` for content removed for good, with the app shell,
  `<meta name="robots" content="noindex, follow">` and `x-robots-tag: noindex`.

### The body

The body accepts content markup only: the elements of `HtmlBodyWriter.tags`
(`main`, `article`, `h1`…`h6`, `p`, `a`, `ul`, `li`, `img`, `table`, `time`…)
and the attributes of `HtmlBodyWriter.attributes` (`id`, `class`, `lang`,
`href`, `src`, `alt`, `rel`, `hreflang`, `datetime`, `itemprop`…), plus any
`data-*` and `aria-*`.

- An element or attribute outside the lists, or an element from another
  namespace (SVG, MathML), throws `ArgumentError`: it is a programming error and
  the response becomes a 500. There is no `script`, `style`, `noscript`,
  `iframe`, `form`, event attribute or `style` attribute. What needs a script
  stays in the app template.
- In `href` and `src`, a URL with a scheme other than `http`/`https`
  (`javascript:`, `data:`), a URL with an authority and no scheme
  (`//other.site`) and a URL that cannot be parsed **only drop the attribute**
  and are reported to `CrawlableObserver.onUrlDropped`, because they usually
  come from user-entered data.
- Text and attribute values are escaped; comments are not written.

Build the body with `Element.tag` and `text`, never with text:

```dart
// Wrong: the name becomes markup.
Element wrongTitle(String name) => Element.html('<h1>$name</h1>');

// Right.
Element rightTitle(String name) => Element.tag('h1')..text = name;
```

## Routes

- A route has literal segments and `:name` parameters: `/:lang/gym/:id`. Every
  route starts with `/` and is lowercase. `*` and typed parameters are not
  supported.
- A path matches without regard to case and ignoring slashes at either end;
  the site then answers 301 to the clean lowercase path, keeping the original
  search. Parameters arrive percent-decoded (`a%20b` → `a b`).
- `HtmlPageRule.query` lists the only search parameters the rule sees and that
  go into the default canonical URL. `?utm_source=…` reaches neither.
- `start()` throws `StateError` for an invalid, repeated or reserved route
  (`/robots.txt`, `/sitemap.xml`, `/sitemaps/…`). The reserved paths are served
  before any rule, so a `/:lang` rule never receives them.
- A path with no rule gets the app shell (the template unchanged) with
  `x-robots-tag: noindex`; a path whose last segment has a dot gets a 404 in
  text.

## Sitemap

```dart
final class GymSitemap implements SitemapSource {
  @override
  String get name => 'gyms';

  @override
  Future<int> bucketCount() async => 64;

  @override
  Future<List<SitemapEntry>> entries(int bucket) async => [
    for (final gym in await gymsInBucket(bucket))
      SitemapEntry(
        '/en/gym/${gym.id}',
        lastModified: gym.updatedAt,
        alternates: [
          SitemapAlternate('en', '/en/gym/${gym.id}'),
          SitemapAlternate('pt', '/pt/gym/${gym.id}'),
          SitemapAlternate('x-default', '/en/gym/${gym.id}'),
        ],
      ),
  ];
}
```

- The site builds `/sitemap.xml` (the index, one file per bucket of each
  source) and `/sitemaps/<source>-<bucket>.xml` on request, with no cron job and
  no stored file.
- **Buckets.** Split your rows into stable buckets, for example
  `id % bucketCount` stored with the row and indexed. Aim for at most 10,000
  rows per bucket: each row becomes one entry per language, and a file holds at
  most 50,000 entries.
- **Protocol limits.** Each file stops before 50,000 entries or 52,428,800
  bytes, and the index before 50,000 files. The cut is reported to
  `onSitemapTruncated` / `onSitemapIndexTruncated` and the response is served
  with what fit: add buckets.
- **`lastModified` only when it is true.** Google ignores `lastmod` on sites
  where it does not match the page. If you cannot keep the date of the last
  visible change, leave it null.
- A source name uses lowercase letters, digits and hyphens (`gyms`,
  `equipment-types`) and is unique; `start()` checks it. An entry on another
  origin or an invalid `hreflang` makes that file a 500.

`/robots.txt` is always served: `User-agent: *`, one `Disallow:` line per item
of `RobotsTxt.disallow` (or `Allow: /` with no items) and, with sources, the
`Sitemap:` line. An entry with a line break makes `start()` throw.

## HTTP behavior

| Status | When |
|---|---|
| 200 | A page; the app shell for a path with no rule; `robots.txt`; the sitemap |
| 301 | A page path with uppercase letters or extra slashes, to the clean path with the original search; also `HtmlRedirect` |
| 302 | `HtmlRedirect(…, permanent: false)` |
| 304 | `If-None-Match` matches the ETag of a 200 (or is `*`), by weak comparison: `W/"x"` and `"x"` are the same ETag |
| 404 | `HtmlNotFound`; a path with no rule whose last segment has a dot; a sitemap file, source or bucket that does not exist; `/sitemap.xml` with no sources |
| 405 | A method other than GET and HEAD, with `allow: GET, HEAD` |
| 410 | `HtmlNotFound(gone: true)` |
| 500 | A rule that throws or returns an invalid page: the app shell, `no-store`, `noindex`, no exception detail. For the sitemap: `Sitemap unavailable` in text |

HEAD answers with the GET headers and an empty body.

Headers:

- `etag`: weak (`W/"…"`), the SHA-1 of the body, on 200 responses only.
- `content-language`: the page `lang`.
- `x-robots-tag: noindex`: shell, 404, 410, 500 and pages with `index: false`.
- `CrawlableSite.defaultHeaders`: `x-content-type-options: nosniff` and
  `referrer-policy: strict-origin-when-cross-origin`, on every response.
  Passing `headers:` replaces the whole map.

### Cache

There is no cache and no compression at the origin: put a CDN in front, which
caches and compresses. `HtmlCachePolicy(browser:, shared:,
staleWhileRevalidate:, staleIfError:)` becomes `public, max-age=…,
s-maxage=…, stale-while-revalidate=…, stale-if-error=…`;
`HtmlCachePolicy.none()` becomes `no-store`.

| `HtmlServerDefaults` | Header |
|---|---|
| `page` (pages and redirects) | `max-age=0, s-maxage=300, stale-while-revalidate=86400, stale-if-error=86400` |
| `notFound` (404 and 410) | `max-age=0, s-maxage=60, stale-while-revalidate=60, stale-if-error=86400` |
| `shell` (path with no rule) | same as `page` |
| `sitemap` (sitemap and `robots.txt`) | `max-age=0, s-maxage=86400, stale-while-revalidate=86400, stale-if-error=86400` |

Failures (500), 405 and the file 404 are `no-store`. Configure the CDN to
ignore, in the cache key, the search parameters your rules do not declare
(`utm_*`, `fbclid`…); otherwise each one becomes a copy.

## Template

- `HtmlTemplateSource.text(html)`: a fixed text (tests, an embedded build).
- `HtmlTemplateSource.url(url, refresh:, timeout:, attempts:, retryDelay:)`:
  the published `index.html` of the web build. Defaults: `refresh` 1 min,
  `timeout` 10 s, `attempts` 5, `retryDelay` 1 s. Every `refresh` the site reads
  it again with `If-None-Match`; a 304 changes nothing and reads never overlap.
- The template needs explicit `<head>` and `<body>` tags, as the Flutter
  `index.html` has; without them, `FormatException`.
- **At startup**, an invalid template throws `FormatException`, and a read that
  keeps failing throws `StateError` with the cause after `attempts` tries.
- **After startup**, a failed read keeps the version in use and is reported to
  `onTemplateFetchFailed`; an invalid new template is reported to
  `onTemplateRejected`.

The shell (path with no rule, 404, 410, 500) is the template unchanged: the
Flutter app starts on it as usual.

## Plugging into your server

`handler` is a shelf `Handler`, so the site fits in any shelf pipeline:

```dart
await site.start();
final handler = const Pipeline()
    .addMiddleware(logRequests())
    .addHandler(site.handler);
await shelf_io.serve(handler, InternetAddress.anyIPv4, 8080);
```

`around` wraps the work of every page and sitemap file. Use it for a database
transaction, a trace or a request id. It calls `work` once; `call.headers` go
into the response, and `call.attributes` describe the work (`path`, `source`,
`bucket`, `written`…):

```dart
final site = CrawlableSite(
  // …
  around: (call, work) async {
    call.headers['x-request-id'] = newRequestId();
    return withTransaction(() => work());
  },
);
```

A throw from `around` or from the work becomes the failure response and
`CrawlableObserver.onFailure`.

`observer` receives the events. The default, `LoggingCrawlableObserver`,
writes to the `make_it_crawlable` logger of `package:logging`. Extend
`CrawlableObserver` and override only what you need:

```dart
final class AlertingObserver extends CrawlableObserver {
  @override
  void onFailure(CrawlableCall call, Object error, StackTrace stack) =>
      alerts.report(call.name, error, stack);
}
```

## Links inside the app

The HTML gives crawlers the first page; links inside the running app must also
be real `<a href>` elements, or the crawler cannot follow them. On the web,
the `Link` widget of `url_launcher` puts a real anchor over its child:

```dart
Link(
  uri: Uri.parse('/en/gym/12'),
  builder: (context, followLink) => InkWell(
    onTap: followLink,
    child: const Text('Iron Temple'),
  ),
)
```

Use the same paths as your rules and your sitemap. Each `Link` is a platform
view on the web, so in a long list put the link on the item, not on every
detail of it. Keep buttons for actions that do not change the page.

## Deployment

- Route the page paths, `/sitemap.xml`, `/sitemaps/*` and `/robots.txt` to the
  site, and the Flutter assets (`main.dart.js`, `flutter_bootstrap.js`,
  `assets/*`, `index.html`) to your static bucket. Read the URL template from
  the bucket, not from the site itself.
- `serve` sets `idleTimeout` to 620 s, above the 600 s idle timeout of Google's
  load balancer; below that, the balancer reuses a closed connection and answers
  502.
- Check the result with the URL Inspection tool of Search Console: it shows the
  rendered HTML and confirms the title, canonical URL and body.

## License

MIT. See [LICENSE](LICENSE).
