import 'dart:async';

import 'package:logging/logging.dart';
import 'package:make_it_crawlable/src/call.dart';
import 'package:make_it_crawlable/src/observer.dart';
import 'package:test/test.dart';

final class _Silent extends CrawlableObserver {}

void main() {
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> sub;

  setUp(() {
    records = [];
    Logger.root.level = Level.ALL;
    sub = Logger.root.onRecord.listen(records.add);
  });

  tearDown(() => sub.cancel());

  const observer = LoggingCrawlableObserver();
  final url = Uri.parse('https://example.org/');
  final error = StateError('boom');
  final stack = StackTrace.current;
  final call = CrawlableCall('HtmlPage /:lang', Uri(path: '/en'));

  LogRecord only() {
    expect(records, hasLength(1));
    expect(records.single.loggerName, 'make_it_crawlable');
    return records.single;
  }

  void expectError(LogRecord r) {
    expect(r.error, isNotNull);
    expect(r.stackTrace, stack);
  }

  test('onServed is FINE', () {
    observer.onServed('/en', 200, const Duration(milliseconds: 3));
    expect(only().level, Level.FINE);
  });

  test('onUrlDropped is INFO', () {
    observer.onUrlDropped('a', 'href');
    expect(only().level, Level.INFO);
  });

  test('onTemplateChanged is INFO', () {
    observer.onTemplateChanged('abc');
    expect(only().level, Level.INFO);
  });

  test('onTemplateRetry is WARNING with the error', () {
    observer.onTemplateRetry(url, 1, error, stack);
    final r = only();
    expect(r.level, Level.WARNING);
    expectError(r);
  });

  test('onTemplateFetchFailed is WARNING with the error', () {
    observer.onTemplateFetchFailed(url, error, stack);
    final r = only();
    expect(r.level, Level.WARNING);
    expectError(r);
  });

  test('onTemplateRejected is SEVERE with the error', () {
    observer.onTemplateRejected(url, const FormatException('bad'), stack);
    final r = only();
    expect(r.level, Level.SEVERE);
    expectError(r);
  });

  test('onFailure is SEVERE with the error', () {
    observer.onFailure(call, error, stack);
    final r = only();
    expect(r.level, Level.SEVERE);
    expectError(r);
  });

  test('onUnexpectedError is SEVERE with the error', () {
    observer.onUnexpectedError('/en', error, stack);
    final r = only();
    expect(r.level, Level.SEVERE);
    expectError(r);
  });

  test('onSitemapIndexTruncated is SEVERE', () {
    observer.onSitemapIndexTruncated(50001);
    expect(only().level, Level.SEVERE);
  });

  test('onSitemapTruncated is SEVERE', () {
    observer.onSitemapTruncated('gyms', 0, 50000);
    expect(only().level, Level.SEVERE);
  });

  test('a subclass without overrides accepts the ten events silently', () {
    final silent = _Silent()
      ..onServed('/en', 200, Duration.zero)
      ..onUrlDropped('a', 'href')
      ..onTemplateRetry(url, 1, error, stack)
      ..onTemplateChanged('abc')
      ..onTemplateRejected(url, const FormatException('bad'), stack)
      ..onTemplateFetchFailed(url, error, stack)
      ..onFailure(call, error, stack)
      ..onUnexpectedError('/en', error, stack)
      ..onSitemapIndexTruncated(1)
      ..onSitemapTruncated('gyms', 0, 1);
    expect(silent, isA<CrawlableObserver>());
    expect(records, isEmpty);
  });
}
