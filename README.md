# Cloudspark

## Structure

- `app/`: macOS app, Xcode project, XcodeGen config, sources.
- `www/`: GitHub Pages landing page.

## App

```fish
cd app
xcodegen generate
open Cloudspark.xcodeproj
```

## Web

```fish
cd www
pnpm install
pnpm dev
pnpm build
```

GitHub Pages deploys from `.github/workflows/deploy-pages.yml`.
The CTA auto-targets GitHub Releases on `*.github.io`; set a custom URL in `www/src/main.js` if you use a custom domain.
