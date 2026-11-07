import 'package:logging/logging.dart';

import 'call.dart';

/// Receives what a `CrawlableSite` reports. Every method does nothing by
/// default: extend this class and override the events you care about.
abstract class CrawlableObserver {
  /// Const constructor for subclasses.
  const CrawlableObserver();

  /// A response left the site for [path], with [status], [elapsed] after the
  /// request arrived.
  void onServed(String path, int status, Duration elapsed) {}

  /// An unsafe `href` or `src` was dropped from the page body.
  void onUrlDropped(String tag, String attribute) {}

  /// Reading the template from [url] failed at startup; the site tries again.
  void onTemplateRetry(Uri url, int attempt, Object error, StackTrace stack) {}

  /// A refresh brought a template with a new [version].
  void onTemplateChanged(String version) {}

  /// A refresh brought an invalid template; the current one stays.
  void onTemplateRejected(Uri url, FormatException error, StackTrace stack) {}

  /// A refresh could not read the template; the current one stays.
  void onTemplateFetchFailed(Uri url, Object error, StackTrace stack) {}

  /// The work of [call] threw, inside `CrawlableSite.around` or out of it;
  /// the site answered with its failure response.
  void onFailure(CrawlableCall call, Object error, StackTrace stack) {}

  /// Something failed outside any page or sitemap work while serving [path];
  /// the site answered 500 with the app shell.
  void onUnexpectedError(String path, Object error, StackTrace stack) {}

  /// The sitemap index passed 50,000 files and was cut.
  void onSitemapIndexTruncated(int files) {}

  /// A sitemap file passed a protocol limit and was cut after [written]
  /// entries.
  void onSitemapTruncated(String source, int bucket, int written) {}
}

/// Writes every event to the `make_it_crawlable` logger of
/// `package:logging`. The default observer of `CrawlableSite`.
class LoggingCrawlableObserver extends CrawlableObserver {
  /// Creates the observer.
  const LoggingCrawlableObserver();

  static final _log = Logger('make_it_crawlable');

  @override
  void onServed(String path, int status, Duration elapsed) =>
      _log.fine('served $path: $status in ${elapsed.inMilliseconds} ms');

  @override
  void onUrlDropped(String tag, String attribute) => _log.info(
    'page body: unsafe URL in <$tag $attribute>, attribute dropped',
  );

  @override
  void onTemplateRetry(Uri url, int attempt, Object error, StackTrace stack) =>
      _log.warning(
        'template: attempt $attempt to read $url failed; retrying',
        error,
        stack,
      );

  @override
  void onTemplateChanged(String version) =>
      _log.info('template: new version $version');

  @override
  void onTemplateRejected(Uri url, FormatException error, StackTrace stack) =>
      _log.severe(
        'template: the new version at $url is invalid; keeping the current one',
        error,
        stack,
      );

  @override
  void onTemplateFetchFailed(Uri url, Object error, StackTrace stack) =>
      _log.warning(
        'template: could not read $url; keeping the current version',
        error,
        stack,
      );

  @override
  void onFailure(CrawlableCall call, Object error, StackTrace stack) => _log
      .severe('${call.name} failed; sent the failure response', error, stack);

  @override
  void onUnexpectedError(String path, Object error, StackTrace stack) =>
      _log.severe('unexpected failure serving $path', error, stack);

  @override
  void onSitemapIndexTruncated(int files) => _log.severe(
    'sitemap: the index passed 50,000 files ($files) and was cut; '
    'use fewer buckets',
  );

  @override
  void onSitemapTruncated(String source, int bucket, int written) =>
      _log.severe(
        'sitemap: $source-$bucket passed a protocol limit and was cut after '
        '$written entries; use more buckets',
      );
}
