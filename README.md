# Verity marketplace pages

The public web pages of the businesses on the Verity marketplace, at
https://surfeith.github.io/landing-pages/. Plain HTML built from the
public Nostr relays, for search engines and share previews. The scrolling
story, bookings and messages stay in the app.

Only what is already public on the relays is read; nothing from Verity's
own code or data is needed.

## What is built

- `index.html`: every business, by town and category.
- `p/<page>.html`: one page per business, with Open Graph tags, a poster
  frame from its video and LocalBusiness structured data.
- `c/<category>/`, `l/<town>/` and `l/<town>/<category>/`: listings that
  rank for "electrician in Ashdod". A town is one listing whatever
  language its pages were placed in: the app attaches the town in
  English to every page.
- `sitemap.xml` and `robots.txt`.
- Everything in `static/`, copied as is: files that must live at a fixed
  path next to the pages, such as Google's ownership proof for Search
  Console.

## How it runs

`.github/workflows/site.yml` rebuilds the site every quarter hour and on
every push, and publishes it with GitHub Pages (Settings → Pages → Source:
GitHub Actions). A business that is withdrawn in the app is left out at
the next build.

To build locally:

```
dart pub get
dart run bin/site.dart --out build --base https://surfeith.github.io/landing-pages
dart test
```
