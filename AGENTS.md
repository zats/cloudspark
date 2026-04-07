# Release Notes

- GitHub release tags use a `v` prefix, e.g. `v1.0.3`.
- GitHub release titles use `Cloudspark X.Y.Z`, e.g. `Cloudspark 1.0.3`.
- The website download URL is hardcoded to `https://github.com/zats/cloudspark/releases/latest/download/Cloudspark-macos.zip` in [www/src/main.js](/Users/zats/Documents/xcode/cloudflare/www/src/main.js#L5).
- Release assets must therefore be uploaded as `Cloudspark-macos.zip`.
- Package the app bundle with `ditto -c -k --keepParent '.../Cloudspark.app' Cloudspark-macos.zip` before uploading.
