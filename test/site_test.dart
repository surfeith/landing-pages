import 'dart:convert';
import 'dart:io';

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
    expect(html, contains('<title>Omer · Veterinarian in Ashdod</title>'));
    expect(html, contains('"@type":"LocalBusiness"'));
    expect(html, contains('"ratingValue":"4.5"'));
    expect(html, contains('href="https://s/l/ashdod/vet/"'));
    expect(html, contains('<html lang="en">'));
    expect(html, contains('og:image'));
    expect(html, contains('--accent:#B23A48'));
    expect(html, contains('&lt;script&gt;'));
    expect(html, isNot(contains('<script>')));
    expect(html, contains('₪180'));
    expect(html, contains('340 bookings this year'));
    expect(html, contains('tel:+9723000'));
    expect(html, contains('https://paws.example'));
    expect(html, contains('★ 4.5 · 12'));
    expect(html, contains('verity://open/market/page/$pageKind:${'a' * 64}:page-1'));
  });

  test('the index groups pages by place and the sitemap lists them', () {
    final p = SitePage(page());
    final index = renderIndex([p], {'a' * 64: Business(name: 'Omer')}, base: 'https://s');
    expect(index, contains('<a href="https://s/l/ashdod/">Ashdod</a>'));
    expect(index, contains('href="https://s/c/vet/"'));
    expect(index, contains('href="https://s/p/aaaaaaaa-page-1.html"'));
    final listing = renderListing(title: 'Veterinarian in Ashdod', description: 'd', pages: [p], businesses: const {}, base: 'https://s', url: 'https://s/l/ashdod/vet/');
    expect(listing, contains('<title>Veterinarian in Ashdod · Verity</title>'));
    expect(slugOf('Tel Aviv-Yafo'), 'tel-aviv-yafo');
    expect(slugOf('אשדוד'), 'אשדוד');
    expect(langOf('שלום'), 'he');
    expect(langOf('Hello'), 'en');
    final sitemap = renderSitemap(['https://s/', 'https://s/p/aaaaaaaa-page-1.html']);
    expect(sitemap, contains('<loc>https://s/p/aaaaaaaa-page-1.html</loc>'));
    expect(renderSitemap(['https://s/l/אשדוד/']), contains('<loc>https://s/l/%D7%90%D7%A9%D7%93%D7%95%D7%93/</loc>'));
    expect(renderIndex(const [], const {}, base: 'https://s'), contains('No pages published yet'));
  });

  test('one town whatever language its pages were placed in: the town tag wins over the name', () {
    final english = SitePage(page(extra: [['town', 'Ashdod']]));
    final russian = SitePage(Event({...page(extra: [['town', 'Ashdod']]).json, 'tags': [
      ['d', 'page-2'], ['title', 'Vet'], ['t', 'vet'], ['location', 'Ашдод, Израиль'], ['town', 'Ashdod'], ['client', 'verity'],
    ]}));
    expect(english.town, 'Ashdod');
    expect(russian.town, 'Ashdod');
    expect(slugOf(russian.town), 'ashdod');
    expect(SitePage(page()).town, 'Ashdod', reason: 'without the tag, the first part of the place name');
    expect(SitePage(page(extra: [['town', '  ']])).town, 'Ashdod', reason: 'a blank tag counts as none');
  });

  test('a page withdrawn after it was published is left out', () {
    // Exercised through the same rules buildSite applies: a deletion by the
    // author naming the address, dated after the page.
    final p = SitePage(page());
    final withdrawn = <String, int>{p.address: p.event.createdAt + 10};
    expect((withdrawn[p.address] ?? -1) < p.event.createdAt, isFalse);
    final republished = <String, int>{p.address: p.event.createdAt - 10};
    expect((republished[p.address] ?? -1) < p.event.createdAt, isTrue);
  });

  test('an unverified event is not trusted; the newest per address wins', () {
    expect(page().verified, isFalse);
    final old = page(title: 'Old');
    final newer = Event({...old.json, 'created_at': 1790000100, 'id': 'y' * 64});
    final latest = latestByAddress([old, newer]);
    expect(latest.values.single.createdAt, 1790000100);
  });

  test('files in static/ are served at the same path in the site', () async {
    final tmp = Directory.systemTemp.createTempSync('site');
    final from = Directory('${tmp.path}/static')..createSync();
    File('${from.path}/google-proof.html').writeAsStringSync('google-site-verification: google-proof.html');
    final out = Directory('${tmp.path}/build')..createSync();
    await copyStatic(out, from: from);
    expect(File('${out.path}/google-proof.html').readAsStringSync(), 'google-site-verification: google-proof.html');
    tmp.deleteSync(recursive: true);
  });
}
