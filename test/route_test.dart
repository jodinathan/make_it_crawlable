import 'package:make_it_crawlable/src/route.dart';
import 'package:test/test.dart';

void main() {
  final route = HtmlRoute.parse('/:lang/gym/:id');

  test('matches and returns the parameters', () {
    expect(route.match('/en/gym/12'), {'lang': 'en', 'id': '12'});
  });

  test(
    'matches without regard to case and keeps the parameters as they came',
    () {
      expect(route.match('/EN/Gym/12'), {'lang': 'EN', 'id': '12'});
    },
  );

  test('ignores slashes at either end', () {
    expect(route.match('/en/gym/12/'), isNotNull);
    expect(route.match('/en/gym/12///'), isNotNull);
    expect(route.match('//en/gym/12'), isNotNull);
  });

  test('a different number of segments does not match', () {
    expect(route.match('/en/gym'), isNull);
    expect(route.match('/en/gym/12/x'), isNull);
  });

  test('an empty segment does not match', () {
    expect(route.match('/en//12'), isNull);
  });

  test('parameters are percent-decoded', () {
    expect(route.match('/en/gym/a%20b'), {'lang': 'en', 'id': 'a b'});
    expect(route.match('/en/gym/s%C3%A3o'), {'lang': 'en', 'id': 'são'});
    expect(route.match('/en/gym/a%2Fb'), {'lang': 'en', 'id': 'a/b'});
  });

  test('a malformed encoding does not match', () {
    expect(route.match('/en/gym/%'), isNull);
    expect(route.match('/en/gym/%C3'), isNull);
  });

  test('the root route matches only the root', () {
    final root = HtmlRoute.parse('/');
    expect(root.match('/'), <String, String>{});
    expect(root.match('//'), <String, String>{});
    expect(root.match('/en'), isNull);
  });

  test('an invalid route throws StateError', () {
    for (final pattern in ['/a/*', '/:id/:id', '/:Id', '/a//b', '/:id:int']) {
      expect(() => HtmlRoute.parse(pattern), throwsStateError, reason: pattern);
    }
  });
}
