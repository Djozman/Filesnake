# Filesnake 1.2.5

## Highlights

- Redesigned Filesnake with a cleaner welcome screen, toolbar, navigation, and app icon.
- Added save-before-open, save-before-close, and save-before-quit protection.
- Added path-traversal protection for unsafe archive entries.
- Improved ZIP fallback extraction and missing-entry reporting.
- Improved RAR metadata parsing and process reliability.
- Added safer rename validation and duplicate-name checks.
- Improved GZIP validation and ZIP rewrite compression.
- Removed unsupported file associations from Finder and app metadata.

## Build

```bash
swift build.swift release
```

The app bundle is written to `build/Filesnake.app`.
