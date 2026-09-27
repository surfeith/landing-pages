// Builds the marketplace web pages from the relays.
//
//   dart run bin/site.dart --out build --base https://surfeith.github.io/landing-pages
import 'dart:io';

import 'package:verity_site/site.dart';

Future<void> main(List<String> args) async {
  var out = 'build';
  var base = 'https://surfeith.github.io/landing-pages';
  var posters = true;
  final relays = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--out':
        out = args[++i];
      case '--base':
        base = args[++i].replaceFirst(RegExp(r'/$'), '');
      case '--relay':
        relays.add(args[++i]);
      case '--no-posters':
        posters = false;
      default:
        stderr.writeln('Unknown argument ${args[i]}');
        exit(64);
    }
  }
  final count = await buildSite(
    out: Directory(out),
    base: base,
    relays: relays.isEmpty ? defaultRelays : relays,
    posters: posters,
  );
  stdout.writeln('$count pages written to $out');
}
