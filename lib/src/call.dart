import 'package:shelf/shelf.dart' show Response;

/// One piece of work that a `CrawlableSite` runs inside its
/// `CrawlableSite.around`: a page or a sitemap file.
///
/// [name] identifies the work (`HtmlPage /:lang/gym/:id`, `Sitemap index`,
/// `Sitemap gyms-0`) and [path] is the requested path. [headers] go into the
/// response, failed or not: the around fills them before calling the work.
/// [attributes] describe the work for tracing, filled by the site as the work
/// goes: `path` for a page; `sources`, `files` and `truncated` for the index;
/// `source`, `bucket`, `written` and `truncated` for a sitemap file.
final class CrawlableCall {
  /// Creates a call for the work [name] on [path].
  CrawlableCall(this.name, this.path);

  /// What the work is.
  final String name;

  /// The requested path, with the declared query parameters for a page.
  final Uri path;

  /// Headers added to the response.
  final Map<String, String> headers = {};

  /// Key and value pairs that describe the work.
  final Map<String, Object> attributes = {};
}

/// Wraps the work of every page and sitemap file: a transaction, a trace, a
/// database session. It calls `work` once and returns its response, or
/// throws; a throw becomes the failure response and
/// `CrawlableObserver.onFailure`.
typedef CrawlableAround =
    Future<Response> Function(
      CrawlableCall call,
      Future<Response> Function() work,
    );
