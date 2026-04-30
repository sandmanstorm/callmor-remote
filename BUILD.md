# Building FerryDesk Remote

This is a fork of [rustdesk/rustdesk](https://github.com/rustdesk/rustdesk) with two
local rebrand changes:

1. **Default rendezvous server + public key** baked in (via fork of
   `hbb_common`). Clients auto-configure against `ferrydesk.com` with no
   manual setup.
2. **App display name, bundle ID, and Windows resource metadata** changed to
   `FerryDesk Remote` / `com.ferrydesk.remote` / `FerryDesk`.

Everything else — build process, dependencies, GUI strings inside the app — is
identical to upstream. Use the **upstream RustDesk build instructions** as your
primary reference; this document only adds FerryDesk-specific notes.

## Cloning

The fork uses a custom `hbb_common` submodule. Always clone recursively:

```bash
git clone --recursive https://github.com/sandmanstorm/callmor-remote.git
```

If you forgot `--recursive`, fix it after the fact:

```bash
git submodule update --init --recursive
```

You should see `libs/hbb_common` checked out from
`https://github.com/sandmanstorm/hbb_common` (not from `rustdesk/hbb_common`).
Verify with:

```bash
grep ferrydesk src/config.rs   # expect: ferrydesk.com + FerryDesk's pub key
```
*(run this from inside `libs/hbb_common`)*

## Build prerequisites

These are the same as upstream RustDesk's Flutter build path. Use the upstream
GitHub Actions workflow as the source of truth:
[`.github/workflows/flutter-build.yml`](.github/workflows/flutter-build.yml).

### Windows

- Visual Studio 2022 Build Tools, Desktop Development with C++ workload
- LLVM (for bindgen)
- Rust toolchain via `rustup`
- Flutter SDK (>= 3.19, current stable is fine)
- Python 3.x (used by `build.py`)
- vcpkg with the libraries listed in `vcpkg.json` installed in classic mode

### macOS

- Xcode + Command Line Tools (`xcode-select --install`)
- Rust toolchain via `rustup`
- Flutter SDK
- Python 3.x
- vcpkg with `vcpkg.json` deps installed
- Apple Developer ID certificate installed in Keychain (for signing)

## Build commands

From the repo root, the upstream `build.py` orchestrates everything:

```bash
python3 build.py --flutter
```

The output binaries land in:

- Windows: `flutter/build/windows/x64/runner/Release/rustdesk.exe`
- macOS:   `flutter/build/macos/Build/Products/Release/FerryDesk Remote.app`

Note the macOS `.app` bundle name reflects our `PRODUCT_NAME` change — that's
how you confirm the rebrand applied. The Windows `.exe` filename remains
`rustdesk.exe` (unchanged for v0; renaming the binary touches many internals).
The Windows file properties (right-click → Properties → Details) will show
`FerryDesk Remote Desktop` and company `FerryDesk`.

## Code signing

### macOS

Apple Developer ID is configured. Sign + notarize after build:

```bash
codesign --deep --force --options runtime \
  --sign "Developer ID Application: <Your Team Name> (<TEAMID>)" \
  "flutter/build/macos/Build/Products/Release/FerryDesk Remote.app"
```

Then notarize via `notarytool`:

```bash
xcrun notarytool submit FerryDesk-Remote.zip \
  --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password> --wait
xcrun stapler staple "FerryDesk Remote.app"
```

### Windows

**No EV cert yet** — builds are unsigned for now. Users will see SmartScreen
warnings on first run; they have to click "More info" → "Run anyway". Procure
an EV code-signing cert before broad distribution.

## Smoke test

After installing the build:

1. Open the app — title bar / About should say **FerryDesk Remote**.
2. ID server field should already say `ferrydesk.com` (no manual config).
3. The status indicator (bottom-left) should turn green within a few seconds —
   that confirms the baked-in pub key matches the one on the running `hbbs`.
4. Run two installed clients and connect via 9-digit ID to verify the full
   rendezvous + relay flow.

## What's NOT branded yet (future work)

- App icon (still RustDesk's icon)
- In-app strings inside dialogs/menus (e.g. "RustDesk Settings") — there are
  dozens of these in the Flutter UI; full sweep deferred.
- Cargo package name (`rustdesk`), binary filenames (`rustdesk.exe`,
  `librustdesk.dll`), service name — internal identifiers, breaking changes
- iOS / Android — out of scope; only Win + Mac targets for now
- Auto-update server URL (RustDesk's update check still points at upstream)

These are tracked for a "deeper rebrand" pass when needed.
