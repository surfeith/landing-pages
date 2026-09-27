import 'dart:convert';

import 'package:test/test.dart';
import 'package:verity_site/site.dart';

void main() {
  Event page({String title = 'Paws Vet', String content = '{}', List<List<String>> extra = const []}) => Event({
        'id': 'x' * 64,
        'pubkey': 'a' * 64,
        'created_at': 1790000000,
        'kind': pageKind,
        'tags': [
          ['d', 'page-1'],
          ['title', title],
          ['summary', 'Open 24/7'],
          ['t', 'vet'],
          ['location', 'Ashdod, Israel'],
          ['client', 'verity'],
          ...extra,
        ],
        'content': content,
        'sig': '0' * 128,
      });

  test('a page renders its words, offers and contacts, escaped', () {
    final story = {
      'accent': '#B23A48',
      'media': {'servers': ['https://host'], 'frames': ['f1', 'f2', 'f3']},
      'scenes': [
        {'kind': 'title', 'title': 'Paws Vet'},
        {'kind': 'text', 'title': 'Hours', 'text': 'Sun-Thu 9-18\n<script>alert(1)</script>'},
        {'kind': 'offer', 'offer': {'view': {'name': 'Check-up', 'price': 180, 'currency': 'ILS', 'sold': 340}}},
        {'kind': 'contact', 'contact': {'phone': '+972 3 000', 'web': 'paws.example'}},
        {'kind': 'photo'},
      ]
    };
    final p = SitePage(page(content: jsonEncode(story)));
    expect(p.slug, 'aaaaaaaa-page-1');
    expect(p.posterUrl, 'https://host/f2');
    final html = renderPage(p, Business(name: 'Omer', rating: 4.5, reviews: 12), base: 'https://s', poster: 'https://s/p/x.jpg');
    expect(html, contains('<title>Paws Vet · Omer</title>'));
    expect(html, contains('og:image'));
    expect(html, contains('--accent:#B23A48'));
    expect(html, contains('&lt;script&gt;'));
    expect(html, isNot(contains('<script>')));
    expect(html, contains('₪180'));
    expect(html, contains('340 bookings this year'));
    expect(html, contains('tel:+9723000'));
    expect(html, contains('https://paws.example'));
    expect(html, contains('★ 4.5 · 12'));
    expect(html, contains('verity://market/page/$pageKind:${'a' * 64}:page-1'));
  });

  test('the index groups pages by place and the sitemap lists them', () {
    final p = SitePage(page());
    final index = renderIndex([p], {'a' * 64: Business(name: 'Omer')}, base: 'https://s');
    expect(index, contains('<h2>Ashdod</h2>'));
    expect(index, contains('href="https://s/p/aaaaaaaa-page-1.html"'));
    final sitemap = renderSitemap(['https://s/', 'https://s/p/aaaaaaaa-page-1.html']);
    expect(sitemap, contains('<loc>https://s/p/aaaaaaaa-page-1.html</loc>'));
    expect(renderIndex(const [], const {}, base: 'https://s'), contains('No pages published yet'));
  });

  test('an unverified event is not trusted; the newest per address wins', () {
    expect(page().verified, isFalse);
    final old = page(title: 'Old');
    final newer = Event({...old.json, 'created_at': 1790000100, 'id': 'y' * 64});
    final latest = latestByAddress([old, newer]);
    expect(latest.values.single.createdAt, 1790000100);
  });
}
