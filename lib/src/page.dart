import 'package:html/dom.dart' show Element;

/// What a page rule returns: a page, a redirect or a not-found answer. The
/// site turns each one into the HTTP response.
sealed class HtmlAnswer {
  /// Base constructor for the answer subclasses.
  const HtmlAnswer();
}

/// A page the crawler reads: a typed head and a body as an element tree.
///
/// [lang] is the page's BCP 47 tag (`en`, `en-US`, `pt-BR`), written to the
/// `lang` of `<html>` and to `Content-Language`. [canonical], the `href` of
/// [alternates] and the image of [social] are paths on the site's origin
/// (`/en/gym/12`) or absolute URLs on it; without [canonical], the canonical
/// URL is the requested path with the parameters declared in the rule. [body]
/// goes at the start of the template's `<body>` and only accepts the elements
/// and attributes of [HtmlBodyWriter.tags] and [HtmlBodyWriter.attributes].
/// [cache] replaces the site's default policy.
final class HtmlPage extends HtmlAnswer {
  /// A page with a [lang] and a [title]; the rest is optional.
  const HtmlPage({
    required this.lang,
    required this.title,
    this.description,
    this.canonical,
    this.alternates = const [],
    this.robots = const HtmlRobots(),
    this.social,
    this.body,
    this.cache,
  });

  /// The page's BCP 47 language tag.
  final String lang;

  /// The `<title>`, which search engines show.
  final String title;

  /// The meta description.
  final String? description;

  /// The canonical URL, as a path on the origin or an absolute URL on it.
  final String? canonical;

  /// The versions of this page in other languages.
  final List<HtmlAlternate> alternates;

  /// What the crawler may do with the page.
  final HtmlRobots robots;

  /// The sharing card.
  final HtmlSocial? social;

  /// The page content, written at the start of the template's `<body>`.
  final Element? body;

  /// The cache policy, replacing the site's default.
  final HtmlCachePolicy? cache;
}

/// Sends the crawler and the person to [location], a path on the same origin.
/// [permanent] answers 301; otherwise, 302.
final class HtmlRedirect extends HtmlAnswer {
  /// A redirect to [location], permanent by default.
  const HtmlRedirect(this.location, {this.permanent = true});

  /// The target path on the same origin.
  final String location;

  /// Whether the redirect is a 301 (true) or a 302 (false).
  final bool permanent;
}

/// There is no page for the path. Answers 404, or 410 with [gone] (content
/// removed for good), with the app shell and `noindex`; [lang] and [title],
/// when given, go to the shell's `<html>` and `<title>`.
final class HtmlNotFound extends HtmlAnswer {
  /// A not-found answer.
  const HtmlNotFound({this.gone = false, this.lang, this.title, this.cache});

  /// Whether the content was removed for good (410) instead of missing (404).
  final bool gone;

  /// The language tag of the shell's `<html>`.
  final String? lang;

  /// The shell's `<title>`.
  final String? title;

  /// The cache policy, replacing the site's default for not-found answers.
  final HtmlCachePolicy? cache;
}

/// The page in another language: [hreflang] is a BCP 47 tag or `x-default`,
/// [href] a path on the same origin.
final class HtmlAlternate {
  /// The version of the page in [hreflang] at [href].
  const HtmlAlternate(this.hreflang, this.href);

  /// A BCP 47 tag or `x-default`.
  final String hreflang;

  /// A path on the same origin.
  final String href;
}

/// What the crawler may do with the page. `<meta name="robots">` is written
/// only when one of the two is false.
final class HtmlRobots {
  /// Indexing and following links, both allowed by default.
  const HtmlRobots({this.index = true, this.follow = true});

  /// Whether the page may be indexed.
  final bool index;

  /// Whether the crawler may follow the page's links.
  final bool follow;

  /// Whether both are allowed, in which case no meta tag is written.
  bool get isDefault => index && follow;

  /// The `content` of `<meta name="robots">`.
  String get content =>
      '${index ? 'index' : 'noindex'}, ${follow ? 'follow' : 'nofollow'}';
}

/// The sharing card (Open Graph and Twitter). [type] is the `og:type`,
/// [locale] the `og:locale` (`en_US`), [image] a path on the same origin or
/// an absolute URL on any origin (an image on a file CDN).
final class HtmlSocial {
  /// A sharing card of [type] `website` by default.
  const HtmlSocial({
    this.type = 'website',
    this.siteName,
    this.locale,
    this.image,
    this.imageAlt,
  });

  /// The `og:type`.
  final String type;

  /// The `og:site_name`.
  final String? siteName;

  /// The `og:locale`, such as `en_US`.
  final String? locale;

  /// The image, as a path on the origin or an absolute URL on any origin.
  final String? image;

  /// The image's alternative text.
  final String? imageAlt;
}

/// The response's `Cache-Control`. [browser] is the `max-age`, [shared] the
/// `s-maxage` (CDN), [staleWhileRevalidate] and [staleIfError] the windows for
/// a stale copy. [HtmlCachePolicy.none] answers `no-store`.
final class HtmlCachePolicy {
  /// A public policy: five minutes on the CDN, one day of stale windows.
  const HtmlCachePolicy({
    this.browser = Duration.zero,
    this.shared = const Duration(minutes: 5),
    this.staleWhileRevalidate = const Duration(days: 1),
    this.staleIfError = const Duration(days: 1),
  }) : store = true;

  /// A policy that answers `no-store`.
  const HtmlCachePolicy.none()
    : browser = Duration.zero,
      shared = Duration.zero,
      staleWhileRevalidate = Duration.zero,
      staleIfError = Duration.zero,
      store = false;

  /// The browser's `max-age`.
  final Duration browser;

  /// The CDN's `s-maxage`.
  final Duration shared;

  /// The `stale-while-revalidate` window.
  final Duration staleWhileRevalidate;

  /// The `stale-if-error` window.
  final Duration staleIfError;

  /// Whether the response may be stored; false answers `no-store`.
  final bool store;

  /// The `Cache-Control` header value.
  String get headerValue => store
      ? 'public, max-age=${browser.inSeconds}, s-maxage=${shared.inSeconds}, '
            'stale-while-revalidate=${staleWhileRevalidate.inSeconds}, '
            'stale-if-error=${staleIfError.inSeconds}'
      : 'no-store';
}
