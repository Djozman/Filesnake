# Filesnake

A native macOS archive viewer. Peek inside `.zip`, `.tar`, `.tar.gz`, and `.gz`
files without extracting. Select files, preview them with Quick Look, and
extract individually or in batches.

Built with SwiftUI + AppKit for macOS 13+.

## Features (v0.1)

- **Browse before extracting** — list every entry in a native Table view
- **Select & batch extract** — Cmd-click rows, Extract Selected or Extract All
- **Individual extraction** — right-click any row, "Extract Selected…"
- **Delete inside ZIP** — remove entries from ZIPs in-place (rewrites archive)
- **Quick Look preview** — uses `QLPreviewView`; works for text, images,
  PDFs, audio, video, and anything Quick Look supports
- **Full search** — toolbar search filters by path as you type
- **Drag & drop** — drop a `.zip`/`.tar.gz`/etc. onto the window to open it
- **Native look** — SwiftUI `NavigationSplitView` with sidebar, list, detail

## Format support

| Format       | List | Extract | Delete | Preview |
|--------------|:----:|:-------:|:------:|:-------:|
| `.zip`       | ✅   | ✅      | ✅     | ✅      |
| `.tar`       | ✅   | ✅      | ❌     | ✅      |
| `.tar.gz`    | ✅   | ✅      | ❌     | ✅      |
| `.gz`        | ✅   | ✅      | ❌     | ✅      |
| `.rar`       | 🚧   | 🚧      | ❌     | 🚧      |

RAR is read-only by nature (proprietary). It will be added in v0.2 via
UnrarKit — that requires vendoring the `unrar` C++ source, which doesn't
fit cleanly in Swift Package Manager.

## Build & run

Requires Xcode 15+ on macOS 13+.

### Option A — Swift Package (quick)

```bash
swift run Filesnake
```

This runs the SwiftUI app directly. Fine for development; no bundle/icon.

### Option B — Xcode

1. `open Package.swift`
2. Product → Run (⌘R)

## Dependencies

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — pure-Swift ZIP read/write
- [SWCompression](https://github.com/tsolomko/SWCompression) — pure-Swift TAR/GZIP/XZ/7z

Both are MIT-licensed and vendored via SwiftPM.

## Project layout

```
Sources/Filesnake/
├── FilesnakeApp.swift          # @main, Commands, drop target
├── Archive/
│   ├── ArchiveFormat.swift     # format detection
│   ├── ArchiveHandler.swift    # protocol + factory
│   ├── ZipHandler.swift        # ZIPFoundation-backed
│   ├── TarHandler.swift        # SWCompression TAR / TAR.GZ
│   ├── GzipHandler.swift       # single-file .gz
│   └── RarHandler.swift        # stub
├── Models/
│   ├── ArchiveEntry.swift
│   └── ArchiveDocument.swift   # observable app state
├── Views/
│   ├── ContentView.swift       # NavigationSplitView
│   ├── SidebarView.swift
│   ├── ArchiveListView.swift
│   ├── ArchiveToolbar.swift
│   ├── PreviewPane.swift       # QLPreviewView wrapper
│   └── EmptyStateView.swift
└── Utils/
    └── Formatters.swift        # bytes, dates, file icons
```

## Roadmap

- **v0.2** — RAR via UnrarKit; password-protected ZIPs; content search
  (grep inside archive)
- **v0.3** — `.xcodeproj` with Document Type + UTI so Finder "Open with
  Filesnake" works; app icon & signing; sandbox & notarization
- **v0.4** — 7z, bz2, xz; nested-archive drill-in ("open archive inside
  archive" without extracting); progress bars on extraction
- **v0.5** — Create new archives (drag files in → build ZIP)

## License

MIT (tentative — add `LICENSE` file).
