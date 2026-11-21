# Document Inbox

A local macOS CLI for searching PDFs, screenshots, and scans. It extracts text with PDFKit or Apple Vision and indexes it in SQLite FTS5. No network or background service required.

## Quick start

Requires macOS 13 or later and Swift 5.9 or later (from Xcode or Apple's Command Line Tools).

```sh
git clone https://github.com/rohanvitrouthu/document-inbox.git
cd document-inbox
swift build
mkdir -p ~/Documents/Inbox
# Put PDFs, PNGs, or JPEGs in the folder before indexing.
.build/debug/inbox index ~/Documents/Inbox
.build/debug/inbox search "invoice 123"
```

Re-run `index` after adding, changing, or deleting files. It scans subfolders and skips unchanged files. Search returns up to 20 ranked pages with matching snippets; all query terms must match the same page.

```sh
.build/debug/inbox open "$HOME/Documents/Inbox/january scan.pdf" 3
```

`open` launches the original image or a temporary, one-page PDF copy. Use `open --print-path` to get the path without launching a viewer.

The database at `~/Library/Application Support/DocumentInbox/index.sqlite3` contains source paths and extracted text. Keep it private. Each database indexes one folder; pass `--db <path>` before `index` or `search` to use another database.

## Smoke test

```sh
swift build && swift Tests/SmokeTest.swift "$(swift build --show-bin-path)/inbox"
```
