# Contributing to Nockerl Voice

Thanks for your interest in improving Nockerl Voice. This document covers how to
get set up, the conventions the codebase follows, and how to get a change merged.

## Getting started

Requirements: macOS 14+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

Clone the repository, generate the Xcode project, and open it:

```bash
git clone https://github.com/dizyx/nockerl-voice
cd nockerl-voice
xcodegen generate            # regenerate NockerlVoice.xcodeproj from project.yml
open NockerlVoice.xcodeproj
```

Swift Package Manager resolves the dependencies on the first build. That includes
the shared **NockerlDesign** design-system package and the MP3 encoder
(swift-lame). You do not need to check anything out beside this repository.

The generated `.xcodeproj` is intentionally git-ignored. **`project.yml` is the
source of truth** for the project structure, build settings, `Info.plist`, and
entitlements. Change those there, not in the generated project, and re-run
`xcodegen generate`.

## Running the tests

Tests are required for behavior changes. Run them before opening a pull request:

```bash
xcodegen generate
xcodebuild test -scheme NockerlVoice -destination 'platform=macOS'
```

## Code style

- **SwiftUI first**, with AppKit interop only where SwiftUI does not reach (the
  menu bar, the global event tap, text insertion). The project builds in the
  Swift 5 language mode and adopts Swift 6 concurrency incrementally, so new code
  should be concurrency-safe even though the mode is not switched on yet.
- Prefer small, focused files. If a file grows past roughly 500 lines, look for a
  natural place to split it.
- Keep UI on the **NockerlDesign** component set. Reach for the shared components
  (cards, form sections, tabs, selects, toggles) before hand-rolling a control, so
  the app stays visually consistent.
- Write clear, self-explanatory names. Comments should explain *why*, not restate
  the code.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep each pull request focused on a single change. Smaller is easier to review.
3. Include tests for new behavior and make sure the full test suite passes.
4. Write a clear description: what changed, why, and how you verified it. Screen
   recordings help for UI changes.
5. Be responsive to review feedback. Maintainers may ask for changes before merge.

## Reporting bugs and requesting features

Open a [GitHub issue](../../issues). For bugs, include your macOS version, the
transcription engine you were using, and clear steps to reproduce. For security
issues, do **not** open a public issue; follow [SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE) that covers this project.
