# Contributing to Forkspaces

Thanks for helping. Keep changes small and focused.

## Requirements

- macOS 13+ (Apple Silicon or Intel)
- Xcode or Command Line Tools (Swift 5.9+)
- Claude Desktop in `/Applications` (needed to create spaces and run the integration test)

## Build and run

```sh
./scripts/build-release.sh
open build/Forkspaces.app
build/Forkspaces.app/Contents/Resources/ForkspacesTool integration build/integration
```

The integration test creates throwaway spaces under `build/integration` and never touches your real spaces.

## Layout

| Path | What |
| --- | --- |
| `Sources/Forkspaces/App.swift` | SwiftUI manager: list, sheets, menus |
| `Sources/Forkspaces/ProfileStore.swift` | Create, edit, duplicate, import, delete spaces; safe data copy |
| `Sources/Forkspaces/BundleBuilder.swift` | Builds and signs a space's launcher from Claude.app |
| `Sources/Forkspaces/Launcher.swift` | Tiny launcher inside each space: checks identity, then runs Claude with its data dir |
| `Sources/Forkspaces/Icon.swift` | Space and app icons |
| `Sources/Forkspaces/Tool.swift` | `ForkspacesTool`: icon generation and integration test |
| `scripts/build-release.sh` | The only build pipeline |

## Pull requests

- Prefer native macOS APIs. Avoid new dependencies.
- Match the surrounding style; no large refactors mixed with features.
- Never parse or log Claude data (cookies, tokens, chats). Treat data folders as opaque.
- Never modify `/Applications/Claude.app` or the user's original Claude data.
- If you touch spaces, launchers, or copying: run the integration test and also try it by hand
  (create, open two spaces at once, stop, duplicate, delete) and say what you tested in the PR.
- Screenshots must use fictional spaces (Personal, Work, Side Project) — no real accounts, emails or conversations.

By contributing you agree your contribution is licensed under this project's [LICENSE](LICENSE).
