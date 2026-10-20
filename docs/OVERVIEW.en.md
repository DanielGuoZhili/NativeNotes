# NativeNotes

Created by [DanielGuoZhili](https://github.com/DanielGuoZhili).

NativeNotes is a native macOS workspace that selectively imports Apple Notes and provides an independent local editor. It keeps Apple Notes as a read-only source: editing or refreshing a local copy never writes changes back.

## What the project implements

- A resizable three-pane workspace built with SwiftUI and AppKit.
- Source search and combined filters for folders, attachments, import state, and locked notes.
- Selective import, offline source snapshots, and manual refresh.
- Local checklists with dedicated drag handles and animated reordering.
- Editable tables with row/column reordering and cell swapping.
- Automatically continuing numeric, alphabetic, and Roman lists.
- Rich text with font styling, sizes, colors, highlights, alignment, spacing, and named links.
- Local persistence, undo/redo, conflict detection, and recovery for failed saves.

## Engineering decisions

The workspace combines SwiftUI views with NSSplitViewController and NSTextView. Source snapshots use Core Data; local documents use structured JSON with optional RTF attributes. No third-party runtime dependencies are required.

Drag interactions freeze layout geometry at pickup to avoid transformed-frame feedback. Per-row movement state limits updates, and text height measurements are cached during pane resizing. Regression checks cover these model-level properties; they do not establish a measured display frame rate.

## Build

Requires macOS 14+ and Swift 5.9+ through Xcode Command Line Tools.

```sh
./verify.sh
./build.sh
open dist/NativeNotes.app
```

For isolated demo data, quit the normal app and run:

```sh
open dist/NativeNotes.app --args --demo
```

The build is ad-hoc signed for local development, not Developer ID signed or notarized. The repository includes a macOS validation workflow and 88 isolated checks that do not read personal Apple Notes.

## Scope and limitations

AppleScript exports can omit original checklist states, table structure, images, or attachments. NativeNotes cannot reconstruct data that the source interface does not provide. Rich text tools currently apply to paragraphs and lists, not table cells. A legacy, title-specific checklist migration is documented in the development guide.

This is an experimental application, not a complete Apple Notes replacement or a bidirectional sync client. No open-source license has been selected yet.

See the [Chinese README](../README.md), [development guide](DEVELOPMENT.md), and [manual acceptance checklist](ACCEPTANCE.md) for details.
