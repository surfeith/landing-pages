/// The public web pages of Verity landing pages: plain HTML built from the
/// relays, for search engines and share previews. The story itself, the
/// bookings and the messages stay in the app; the web page is what a page
/// says, its offers, a poster frame, and a link into the app.
///
/// Reads only what is public on the relays. Runs anywhere Dart runs.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const pageKind = 30777;
const reviewKind = 30775;
const profileKind = 0;

const defaultRelays = ['wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net'];

/// A Nostr event as the relays send it, verified.
class Event {
  Event(this.json)
      : id = json['id'] as String,
        pubkey = json['pubkey'] as String,
        createdAt = json['created_at'] as int,
        kind = json['kind'] as int,
        tags = [
          for (final t in json['tags'] as List) [for (final v in t as List) '$v']
        ],
        content = json['content'] as String;

  final Map<String, dynamic> json;
  final String id, pubkey, content;
  final int createdAt, kind;
  final List<List<String>> tags;

  String? tag(String name) {
    for (final t in tags) {
      if (t.length > 1 && t.first == name) return t[1];
    }
    return null;
  }

  List<String> tagValues(String name) => [
        for (final t in tags)
          if (t.length > 1 && t.first == name) t[1]
      ];

  bool get verified {
    final expected =
        sha256.convert(utf8.encode(jsonEncode([0, pubkey, createdAt, kind, tags, content]))).toString();
    if (expected != id) return false;
    try {
      return bip340.verify(pubkey, id, json['sig'] as String);
    } catch (_) {
      return false;
    }
  }

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(createdAt * 1000, isUtc: true);
}

/// Asks [relays] for [filters] and returns what they hold, once each.
Future<List<Event>> fetch(List<String> relays, List<Map<String, dynamic>> filters,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final byId = <String, Event>{};
  await Future.wait(relays.map((url) async {
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url.endsWith('/') ? url : '$url/'));
      await channel.ready.timeout(const Duration(seconds: 8));
      channel.sink.add(jsonEncode(['REQ', 'site', ...filters]));
      final done = Completer<void>();
      final sub = channel.stream.listen((message) {
        final json = jsonDecode('$message') as List;
        if (json.first == 'EVENT') {
          final event = Event(json[2] as Map<String, dynamic>);
          if (event.verified) byId[event.id] = event;
        } else if (json.first == 'EOSE' && !done.isCompleted) {
          done.complete();
        }
      }, onError: (_) {
        if (!done.isCompleted) done.complete();
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      });
      await done.future.timeout(timeout, onTimeout: () {});
      await sub.cancel();
      await channel.sink.close();
    } catch (error) {
      stderr.writeln('$url: $error');
    }
  }));
  return byId.values.toList();
}

/// The newest event per address (kind:pubkey:d), verified.
Map<String, Event> latestByAddress(Iterable<Event> events) {
  final out = <String, Event>{};
  for (final e in events) {
    final address = '${e.kind}:${e.pubkey}:${e.tag('d') ?? ''}';
    if (!out.containsKey(address) || out[address]!.createdAt < e.createdAt) out[address] = e;
  }
  return out;
}

String esc(Object? v) => const HtmlEscape(HtmlEscapeMode.element).convert('${v ?? ''}');
String escAttr(Object? v) => const HtmlEscape(HtmlEscapeMode.attribute).convert('${v ?? ''}');

/// A page as the site shows it.
class SitePage {
  SitePage(this.event) : story = _story(event);
  final Event event;
  final Map<String, dynamic> story;

  static Map<String, dynamic> _story(Event e) {
    try {
      final json = jsonDecode(e.content);
      return json is Map<String, dynamic> ? json : const {};
    } catch (_) {
      return const {};
    }
  }

  String get id => event.tag('d') ?? '';
  String get address => '$pageKind:${event.pubkey}:$id';
  String get title => event.tag('title') ?? '';
  String get summary => event.tag('summary') ?? '';
  String get category => event.tag('t') ?? 'other';
  String get place => event.tag('location') ?? '';
  String get accent => RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch('${story['accent']}') ? '${story['accent']}' : '#315C53';
  List<Map> get scenes => (story['scenes'] as List? ?? const []).whereType<Map>().toList();
  Map? get media => story['media'] is Map ? story['media'] as Map : null;

  /// A middle frame of the video, if any, from the first host.
  String? get posterUrl {
    final m = media;
    if (m == null) return null;
    final frames = (m['frames'] as List? ?? const []).cast<String>();
    final servers = (m['servers'] as List? ?? const []).cast<String>();
    if (frames.isEmpty || servers.isEmpty) return null;
    return '${servers.first}/${frames[frames.length ~/ 2]}';
  }

  /// The file name on the site: author prefix and page id, safe for a path.
  String get slug =>
      '${event.pubkey.substring(0, 8)}-${id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '')}'.toLowerCase();
}

class Business {
  Business({this.name = '', this.about = '', this.picture, this.rating, this.reviews = 0});
  final String name;
  final String about;
  final String? picture;
  final double? rating;
  final int reviews;
}

/// Builds the site into [out]. [base] is the site's public root, for the
/// sitemap and share previews.
Future<int> buildSite({
  required Directory out,
  required String base,
  List<String> relays = defaultRelays,
  Duration since = const Duration(days: 60),
  bool posters = true,
}) async {
  final sinceAt = DateTime.now().subtract(since).millisecondsSinceEpoch ~/ 1000;
  final pageEvents = latestByAddress(await fetch(relays, [
    {'kinds': [pageKind], 'since': sinceAt},
  ]));
  // Other apps use kind 30777 for their own things: only Verity's pages.
  final pages = [for (final e in pageEvents.values) if (e.tag('client') == 'verity') SitePage(e)]
    ..removeWhere((p) => p.title.isEmpty || p.id.isEmpty)
    ..sort((a, b) => b.event.createdAt.compareTo(a.event.createdAt));
  final authors = {for (final p in pages) p.event.pubkey}.toList();
  final businesses = <String, Business>{};
  if (authors.isNotEmpty) {
    final extra = await fetch(relays, [
      {'kinds': [profileKind], 'authors': authors},
      {'kinds': [reviewKind], '#p': authors},
    ]);
    final profiles = latestByAddress(extra.where((e) => e.kind == profileKind));
    final reviews = latestByAddress(extra.where((e) => e.kind == reviewKind && e.tag('d') == e.tag('p') && e.pubkey != e.tag('p')));
    for (final author in authors) {
      final profile = profiles['$profileKind:$author:'];
      Map<String, dynamic> card = const {};
      if (profile != null) {
        try {
          card = (jsonDecode(profile.content) as Map).cast<String, dynamic>();
        } catch (_) {}
      }
      final ratings = [
        for (final r in reviews.values)
          if (r.tag('p') == author) int.tryParse(r.tag('rating') ?? '') ?? 0
      ].where((r) => r >= 1 && r <= 5).toList();
      businesses[author] = Business(
        name: '${card['name'] ?? ''}',
        about: '${card['about'] ?? ''}',
        picture: card['picture'] is String && '${card['picture']}'.startsWith('https://') ? '${card['picture']}' : null,
        rating: ratings.isEmpty ? null : ratings.reduce((a, b) => a + b) / ratings.length,
        reviews: ratings.length,
      );
    }
  }

  await out.create(recursive: true);
  final pageDir = Directory('${out.path}/p')..createSync(recursive: true);
  final client = http.Client();
  final urls = <String>['$base/'];
  for (final page in pages) {
    final business = businesses[page.event.pubkey] ?? Business();
    String? poster;
    if (posters && page.posterUrl != null) {
      try {
        final r = await client.get(Uri.parse(page.posterUrl!)).timeout(const Duration(seconds: 20));
        if (r.statusCode == 200 && r.bodyBytes.length > 4 && r.bodyBytes[0] == 0xFF) {
          final file = File('${pageDir.path}/${page.slug}.jpg');
          await file.writeAsBytes(r.bodyBytes);
          poster = '$base/p/${page.slug}.jpg';
        }
      } catch (error) {
        stderr.writeln('poster ${page.slug}: $error');
      }
    }
    await File('${pageDir.path}/${page.slug}.html').writeAsString(renderPage(page, business, base: base, poster: poster));
    urls.add('$base/p/${page.slug}.html');
  }
  await File('${out.path}/index.html').writeAsString(renderIndex(pages, businesses, base: base));
  await File('${out.path}/sitemap.xml').writeAsString(renderSitemap(urls));
  await File('${out.path}/robots.txt').writeAsString('User-agent: *\nAllow: /\nSitemap: $base/sitemap.xml\n');
  await File('${out.path}/.nojekyll').writeAsString('');
  client.close();
  return pages.length;
}

const _css = '''
:root{--accent:#315C53}*{box-sizing:border-box}body{margin:0;font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:#1b1f1d;background:#f6f5f2}
a{color:inherit}header.hero{background:linear-gradient(160deg,color-mix(in srgb,var(--accent) 88%,white),color-mix(in srgb,var(--accent) 65%,black));color:#fff;padding:48px 20px;text-align:center}
header.hero img{max-width:100%;max-height:60vh;border-radius:16px;box-shadow:0 12px 40px rgba(0,0,0,.35)}header.hero h1{font-size:2rem;margin:.6em 0 .2em}
header.hero p{max-width:640px;margin:0 auto;opacity:.9}main{max-width:720px;margin:0 auto;padding:24px 16px}
section.scene{background:#fff;border-radius:16px;padding:20px;margin:16px 0;box-shadow:0 2px 12px rgba(0,0,0,.06)}section.scene h2{margin:0 0 .4em;font-size:1.3rem}
.price{font-size:1.6rem;font-weight:800;color:var(--accent)}.facts span{display:inline-block;background:#eef0ee;border-radius:99px;padding:4px 10px;margin:4px 6px 0 0;font-size:.9rem}
.cta{display:block;text-align:center;background:var(--accent);color:#fff;text-decoration:none;font-weight:700;padding:14px;border-radius:99px;margin:24px 0}
.meta{color:#5a615e;font-size:.95rem}.stars{color:#c9a227;font-weight:600}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:16px}.card{background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.06);text-decoration:none}
.card .swatch{height:120px;background:var(--accent)}.card .body{padding:14px}.card h3{margin:0 0 4px}footer{text-align:center;color:#5a615e;padding:32px 16px;font-size:.9rem}
''';

String renderPage(SitePage page, Business business, {required String base, String? poster}) {
  final title = page.title;
  final desc = page.summary.isNotEmpty ? page.summary : '${business.name.isNotEmpty ? '${business.name} · ' : ''}${page.place}';
  final b = StringBuffer()
    ..writeln('<!doctype html><html lang="he"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    ..writeln('<title>${esc(title)}${business.name.isNotEmpty ? ' · ${esc(business.name)}' : ''}</title>')
    ..writeln('<meta name="description" content="${escAttr(desc)}">')
    ..writeln('<link rel="canonical" href="${escAttr('$base/p/${page.slug}.html')}">')
    ..writeln('<meta property="og:type" content="website"><meta property="og:title" content="${escAttr(title)}"><meta property="og:description" content="${escAttr(desc)}">')
    ..writeln('<meta property="og:url" content="${escAttr('$base/p/${page.slug}.html')}">');
  if (poster != null) {
    b.writeln('<meta property="og:image" content="${escAttr(poster)}"><meta name="twitter:card" content="summary_large_image">');
  }
  b.writeln('<style>$_css:root{--accent:${page.accent}}</style></head><body>');
  b.writeln('<header class="hero">');
  if (poster != null) b.writeln('<img src="${escAttr(poster)}" alt="">');
  b.writeln('<h1>${esc(title)}</h1>');
  if (page.summary.isNotEmpty) b.writeln('<p>${esc(page.summary)}</p>');
  final by = [
    if (business.name.isNotEmpty) esc(business.name),
    if (page.place.isNotEmpty) esc(page.place),
    if (business.rating != null) '<span class="stars">★ ${business.rating!.toStringAsFixed(1)} · ${business.reviews}</span>',
  ].join(' · ');
  if (by.isNotEmpty) b.writeln('<p class="meta" style="color:#fff;opacity:.85">$by</p>');
  b.writeln('</header><main>');
  for (final scene in page.scenes) {
    final kind = '${scene['kind']}';
    if (kind == 'title') continue;
    final t = '${scene['title'] ?? ''}'.trim();
    final text = '${scene['text'] ?? ''}'.trim();
    final offer = scene['offer'] is Map ? scene['offer'] as Map : null;
    final view = offer?['view'] is Map ? offer!['view'] as Map : null;
    final contact = scene['contact'] is Map ? scene['contact'] as Map : null;
    if (t.isEmpty && text.isEmpty && view == null && (contact == null || contact.isEmpty)) continue;
    b.writeln('<section class="scene">');
    final heading = t.isNotEmpty ? t : (view != null ? '${view['name'] ?? ''}' : '');
    if (heading.isNotEmpty) b.writeln('<h2>${esc(heading)}</h2>');
    if (text.isNotEmpty) b.writeln('<p>${esc(text).replaceAll('\n', '<br>')}</p>');
    if (view != null) {
      final price = view['price'];
      if (price is num) b.writeln('<p class="price">${esc(_money(price, '${view['currency'] ?? ''}'))}</p>');
      final facts = <String>[
        if (view['stock'] is num && (view['stock'] as num) > 0) '${(view['stock'] as num).round()} in stock',
        if (view['sold'] is num && (view['sold'] as num) > 0) '${(view['sold'] as num).round()} bookings this year',
        if (view['customers'] is num && (view['customers'] as num) > 0) '${(view['customers'] as num).round()} clients served',
      ];
      if (facts.isNotEmpty) b.writeln('<p class="facts">${facts.map((f) => '<span>${esc(f)}</span>').join()}</p>');
    }
    if (contact != null) {
      for (final entry in contact.entries) {
        final v = '${entry.value}'.trim();
        if (v.isEmpty) continue;
        final href = switch ('${entry.key}') {
          'phone' => 'tel:${v.replaceAll(RegExp(r'[^0-9+]'), '')}',
          'whatsapp' => 'https://wa.me/${v.replaceAll(RegExp(r'[^0-9]'), '')}',
          'email' => 'mailto:$v',
          'address' => 'https://www.google.com/maps/search/?api=1&query=${Uri.encodeQueryComponent(v)}',
          _ => v.startsWith('http') ? v : 'https://$v',
        };
        b.writeln('<p><a href="${escAttr(href)}">${esc(v)}</a></p>');
      }
    }
    b.writeln('</section>');
  }
  b.writeln('<a class="cta" href="${escAttr('verity://market/page/${page.address}')}">Open in Verity</a>');
  b.writeln('<p class="meta">Published ${esc(page.event.time.toIso8601String().substring(0, 10))} · <a href="$base/">All pages</a></p>');
  b.writeln('</main><footer>Verity marketplace · pages are signed by their owners and served from public relays.</footer></body></html>');
  return b.toString();
}

String _money(num value, String currency) {
  final text = value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
  final symbol = switch (currency.toUpperCase()) {
    'ILS' => '₪',
    'USD' => r'$',
    'EUR' => '€',
    'GBP' => '£',
    'RUB' => '₽',
    _ => currency.isEmpty ? '' : '$currency ',
  };
  return '$symbol$text';
}

String renderIndex(List<SitePage> pages, Map<String, Business> businesses, {required String base}) {
  final b = StringBuffer()
    ..writeln('<!doctype html><html lang="he"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    ..writeln('<title>Verity marketplace</title><meta name="description" content="Businesses near you: their pages, offers and bookings.">')
    ..writeln('<link rel="canonical" href="${escAttr('$base/')}"><style>$_css</style></head><body>')
    ..writeln('<header class="hero"><h1>Verity marketplace</h1><p>Businesses and their pages, by place.</p></header><main>');
  final byPlace = <String, List<SitePage>>{};
  for (final p in pages) {
    byPlace.putIfAbsent(p.place.split(',').first.trim(), () => []).add(p);
  }
  for (final entry in byPlace.entries) {
    b.writeln('<h2>${esc(entry.key.isEmpty ? 'Elsewhere' : entry.key)}</h2><div class="grid">');
    for (final p in entry.value) {
      final biz = businesses[p.event.pubkey];
      b.writeln('<a class="card" href="${escAttr('$base/p/${p.slug}.html')}" style="--accent:${p.accent}"><div class="swatch"></div><div class="body"><h3>${esc(p.title)}</h3>'
          '<div class="meta">${esc(p.category)}${biz != null && biz.name.isNotEmpty ? ' · ${esc(biz.name)}' : ''}'
          '${biz?.rating != null ? ' · <span class="stars">★ ${biz!.rating!.toStringAsFixed(1)}</span>' : ''}</div></div></a>');
    }
    b.writeln('</div>');
  }
  if (pages.isEmpty) b.writeln('<p class="meta">No pages published yet.</p>');
  b.writeln('</main><footer>Verity marketplace · pages are signed by their owners and served from public relays.</footer></body></html>');
  return b.toString();
}

String renderSitemap(List<String> urls) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
    '${urls.map((u) => '  <url><loc>${esc(u)}</loc></url>').join('\n')}\n</urlset>\n';
