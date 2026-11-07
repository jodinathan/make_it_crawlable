import 'package:html/dom.dart';
import 'package:make_it_crawlable/make_it_crawlable.dart';

const _indexHtml = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Example</title>
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
''';

const _gyms = {1: 'Iron Temple', 2: 'Blue Box'};

final class GymSitemap implements SitemapSource {
  @override
  String get name => 'gyms';

  @override
  Future<int> bucketCount() async => 1;

  @override
  Future<List<SitemapEntry>> entries(int bucket) async => [
    for (final id in _gyms.keys) SitemapEntry('/en/gym/$id'),
  ];
}

Future<void> main() async {
  final site = CrawlableSite(
    origin: Uri.parse('http://localhost:8080'),
    template: const HtmlTemplateSource.text(_indexHtml),
    pages: [
      HtmlPageRule(
        route: '/:lang/gym/:id',
        resolve: (request) async {
          final name = _gyms[int.tryParse(request.params['id']!)];
          if (request.params['lang'] != 'en' || name == null) {
            return const HtmlNotFound(lang: 'en');
          }
          return HtmlPage(
            lang: 'en',
            title: name,
            description: '$name, a gym on the example site.',
            body: Element.tag('main')..append(Element.tag('h1')..text = name),
          );
        },
      ),
    ],
    sitemaps: [GymSitemap()],
  );
  await site.start();
  final server = await site.serve(8080);
  print('Serving on http://localhost:${server.port}/en/gym/1');
}
