<p align="center"><img src="docs/images/icon.png" width="128" alt="Forkspaces icon"></p>

<h1 align="center">Forkspaces</h1>

<p align="center"><b>Forkspaces creates isolated spaces for desktop apps on macOS.</b></p>

Forkspaces is a native macOS utility for running isolated app profiles side by side.
Initially built for Claude Desktop, Forkspaces creates independent spaces with separate sessions,
application data, launchers and custom icons — without modifying the original application.

Forkspaces is source-available and free for personal and internal business use.

<!-- Screenshot: add docs/images/screenshot.png (fictional spaces only: Personal, Work, Side Project). -->

## Features

- Multiple isolated Claude Desktop spaces
- Run multiple accounts side by side
- Independent sessions and app data
- Custom icons (PNG, JPEG, HEIC), initials and colors
- Duplicate spaces
- Import existing Claude data
- Native macOS app (SwiftUI, no dependencies)
- Local-only
- Original Claude installation remains untouched

Today Forkspaces supports Claude Desktop only. The design could support other apps later; nothing beyond Claude is promised yet.

## Requirements

- macOS 13 or later
- Apple Silicon
- [Claude Desktop](https://claude.ai/download) installed in `/Applications`

## Installation

1. Download `Forkspaces.dmg` from [Releases](../../releases) and open it.
2. Drag `Forkspaces.app` to `Applications`.
3. Release builds are not notarized yet. The first time, open it from **System Settings → Privacy & Security → Open Anyway**
   (or run `xattr -dr com.apple.quarantine /Applications/Forkspaces.app`).

## Build from Source

Requires Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/gustavomaia/forkspaces.git
cd forkspaces
./scripts/build-release.sh          # → build/Forkspaces.app and build/Forkspaces.dmg
open build/Forkspaces.app
```

Builds are signed ad-hoc by default, so no Apple Developer account is needed.
To sign with your own identity, use `SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-release.sh`.
The version comes from [`VERSION`](VERSION).

To publish a release: `./scripts/release.sh 0.2.0`. It sets `VERSION`, builds and verifies `Forkspaces.dmg`,
then asks before committing, tagging `v0.2.0`, pushing and publishing the GitHub Release (dmg + SHA-256) with `gh`.

Integration tests build real spaces in a throwaway folder (they need Claude Desktop installed):

```sh
build/Forkspaces.app/Contents/Resources/ForkspacesTool integration build/integration
```

## How It Works

```
/Applications/Claude.app  (never modified)
        │  local APFS copy, own bundle ID, ad-hoc signature
        ▼
~/Applications/Forkspaces/Claude Work.app      ──▶  …/Forkspaces/profiles/work-…/
~/Applications/Forkspaces/Claude Personal.app  ──▶  …/Forkspaces/profiles/personal-…/
```

Each space gets its own copy of Claude with its own bundle identifier, icon and data directory
(`--user-data-dir`), so sessions, cookies and settings never mix. Copies use APFS clones,
so they take little extra disk space. After Claude updates, use **Rebuild from Claude** on each space.

Spaces separate accounts; they are not a security sandbox. All spaces run as your macOS user,
and some system logs and services remain shared.

## Privacy

Everything runs locally on your Mac.

- No backend, no Forkspaces account, no telemetry, analytics or tracking, no cloud sync.
- Forkspaces never reads chats, cookies, tokens, credentials or history.
- Duplicate and import copy Claude's data folder as an opaque whole. The only Claude file Forkspaces
  edits is a space's own `claude_desktop_config.json`, to switch off auto-update and deep-link
  registration inside that space.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

Source-available under the **MIT License with the Commons Clause** — see [LICENSE](LICENSE).

In short (the LICENSE text is what counts):

- Free to use, study, modify, fork and share at no charge, including for personal and educational use.
- **Commercial internal use is permitted.** Companies and their employees can use Forkspaces in their own operations and customize it internally.
- You may not sell Forkspaces or a fork of it, charge for access to it, or offer a paid product or hosted service whose value comes substantially from Forkspaces.
- Keep the copyright and license notices.

Forkspaces is not "open source" as defined by the OSI.

## Unofficial Project

Forkspaces is an independent project and is not affiliated with, endorsed by, or sponsored by Anthropic.
Claude is a product and trademark of Anthropic.
Forkspaces does not distribute Claude Desktop. Users must install the official Claude Desktop application separately.
