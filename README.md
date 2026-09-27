# Verity marketplace pages

Plain HTML for the landing pages businesses publish in the Verity
marketplace, built from the public Nostr relays: for search engines and
share previews. The scrolling story, bookings and messages stay in the app.

```
dart pub get
dart run bin/site.dart --out build --base https://surfeith.github.io/landing-pages
```

Writes `index.html` (pages by place), `p/<page>.html` per page with Open
Graph tags and a poster frame, `sitemap.xml` and `robots.txt`.

`.github/workflows/site.yml` rebuilds every quarter hour and publishes with GitHub
Pages. It needs a **public** repository (Pages is not available on private
ones on a free plan) with Settings → Pages → Source set to GitHub Actions.
This folder is the whole site: copy it into that repository as is.

Only what is already public on the relays is read; nothing from Verity's
own code or data is needed.
