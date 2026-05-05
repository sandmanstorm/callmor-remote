# Building FerryDesk Remote

This is a fork of [rustdesk/rustdesk](https://github.com/rustdesk/rustdesk) with
two local rebrand changes:

1. **Default rendezvous server + public key** baked in (via fork of
   `hbb_common`). Clients auto-configure against `ferrydesk.com` with no manual
   setup.
2. **App display name, bundle ID, and Windows resource metadata** changed to
   `FerryDesk Remote` / `com.ferrydesk.remote` / `FerryDesk`.

The build process below has been verified end-to-end on macOS arm64 (M-series
Mac) and follows the upstream RustDesk Flutter build path with FerryDesk-
specific notes baked in.

## Cloning

The fork uses a custom `hbb_common` submodule (sandmanstorm/hbb_common, branch
`ferrydesk`). Always clone recursively:

```bash
git clone --recursive https://github.com/sandmanstorm/ferrydesk-remote.git
```

If you forgot `--recursive`:

```bash
git submodule update --init --recursive
```

Sanity-check the submodule:

```bash
cd libs/hbb_common
grep -E "ferrydesk\\.com|FerryDesk" src/config.rs | head -3
# expect:
#   m.insert("custom-rendezvous-server".to_string(), "ferrydesk.com".to_string());
#   pub const RENDEZVOUS_SERVERS: &[&str] = &["ferrydesk.com"];
#   pub static ref APP_NAME: RwLock<String> = RwLock::new("FerryDesk Remote".to_owned());
```

If `APP_NAME` still says `RustDesk`, the submodule is on the wrong commit.
Run `git submodule update --init --recursive --force` from the repo root.

## Build prerequisites

### macOS (arm64)

| Tool | Version known to work | Where |
| --- | --- | --- |
| Xcode + Command Line Tools | 15+ | `xcode-select --install` |
| Rust toolchain | stable, aarch64-apple-darwin | `rustup` |
| Flutter SDK | **3.24.5** (NOT 3.41+ — too new for FRB 1.80) | `~/flutter-3.24.5/bin/flutter` |
| Ruby | 4.0.x via Homebrew (system Ruby 2.6 is broken with current CocoaPods) | `brew install ruby` |
| CocoaPods | 1.16.2 | `gem install cocoapods` (after Homebrew Ruby is on PATH) |
| Python | 3.x | system |
| vcpkg | classic mode (not manifest) with deps installed | externally — see below |
| `flutter_rust_bridge_codegen` | **1.80.1** (must match `flutter_rust_bridge = "=1.80"` in Cargo.toml) | `cargo install flutter_rust_bridge_codegen --version 1.80.1` |

> **Why pinned Flutter 3.24.5 and not stable?** RustDesk 1.5.x targets Dart 3.5,
> and stable Flutter ships Dart 3.7+ which breaks compilation with
> `Undefined name 'SemanticsFlags'`-style errors. Install 3.24.5 separately at
> `~/flutter-3.24.5/` and reference it explicitly — do not rely on
> `which flutter` (Homebrew may override; see "Gotchas" below).

vcpkg deps for arm64-osx (one-time, ~30 minutes from source):

```bash
git clone https://github.com/microsoft/vcpkg ~/vcpkg
cd ~/vcpkg && ./bootstrap-vcpkg.sh
./vcpkg install libvpx libyuv opus aom libjpeg-turbo --triplet=arm64-osx
```

### Windows

| Tool | Version known to work |
| --- | --- |
| Visual Studio 2022 Build Tools | Desktop Development with C++ workload |
| LLVM | for bindgen |
| Rust toolchain | stable, x86_64-pc-windows-msvc |
| Flutter SDK | 3.24.5 (same pin as Mac) |
| Python | 3.x |
| vcpkg | classic mode with deps installed |

Use the upstream GitHub Actions workflow as the authoritative reference:
[`.github/workflows/flutter-build.yml`](.github/workflows/flutter-build.yml).

## Build commands

### macOS (verified end-to-end)

The upstream `python3 build.py --flutter` works in principle but assumes a
specific layout. The breakdown below does the same steps explicitly and
matches the verified working path.

```bash
# Hide Homebrew flutter so package_config.json can't get rewritten to point at
# the wrong SDK. Always invoke the pinned binary by its absolute path.
export PATH="/Users/pasha/flutter-3.24.5/bin:/opt/homebrew/opt/ruby/bin:/Users/pasha/.gem/ruby/4.0.0/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cd /path/to/ferrydesk-remote

# 1. Build the Rust dylib + service binary (~3 min on M-series)
MACOSX_DEPLOYMENT_TARGET=10.15 \
  SODIUM_LIB_DIR=/opt/homebrew/lib SODIUM_SHARED=1 \
  VCPKG_ROOT=$HOME/vcpkg \
  cargo build --features flutter --release --lib --bin service

cp target/release/liblibrustdesk.dylib target/release/librustdesk.dylib

# 2. Generate the Flutter <-> Rust FFI bridge
~/.cargo/bin/flutter_rust_bridge_codegen \
  --rust-input ./src/flutter_ffi.rs \
  --dart-output ./flutter/lib/generated_bridge.dart \
  --c-output ./flutter/macos/Runner/bridge_generated.h \
  --class-name Rustdesk

# 3. Resolve Flutter dependencies (with PATH hidden — see Gotchas)
rm -rf flutter/.dart_tool flutter/build
cd flutter
env -i HOME="$HOME" \
    PATH="/Users/pasha/flutter-3.24.5/bin:/opt/homebrew/opt/ruby/bin:/Users/pasha/.gem/ruby/4.0.0/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    /Users/pasha/flutter-3.24.5/bin/flutter pub get

# Sanity check: must point at the pinned SDK, NOT /opt/homebrew/share/flutter
grep -A1 '"name": "flutter"' .dart_tool/package_config.json | head -3

# 4. Build the macOS app
xattr -cr . ../target 2>/dev/null
env -i HOME="$HOME" \
    PATH="/Users/pasha/flutter-3.24.5/bin:/opt/homebrew/opt/ruby/bin:/Users/pasha/.gem/ruby/4.0.0/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    /Users/pasha/flutter-3.24.5/bin/flutter build macos --release
cd ..

# 5. Pack service binary, ad-hoc sign with hardened runtime + entitlements
APP="flutter/build/macos/Build/Products/Release/FerryDesk Remote.app"
cp -f target/release/service "$APP/Contents/MacOS/"
xattr -cr "$APP"

# If a previous run left a malformed signature, remove it first
codesign --remove-signature "$APP" 2>/dev/null

codesign --force --deep --sign - \
  --entitlements flutter/macos/Runner/Release.entitlements \
  -o runtime "$APP"
codesign --verify "$APP" && echo "valid"
```

The result is a working ad-hoc-signed `.app` bundle suitable for local testing.
For distribution see "Code signing → macOS (distribution)" below.

### Windows

```bat
set PATH=%PATH%;C:\path\to\flutter-3.24.5\bin;C:\path\to\vcpkg
set VCPKG_ROOT=C:\path\to\vcpkg

cargo build --features flutter --release --lib --bin service
flutter_rust_bridge_codegen ^
  --rust-input ./src/flutter_ffi.rs ^
  --dart-output ./flutter/lib/generated_bridge.dart ^
  --class-name Rustdesk

cd flutter
flutter pub get
flutter build windows --release
cd ..

REM Output:
REM   flutter\build\windows\x64\runner\Release\rustdesk.exe
REM   (binary name unchanged — renaming touches many internals; bundle metadata
REM    surfaces "FerryDesk Remote" in file properties and About dialog)
```

The CI workflow `.github/workflows/flutter-build.yml` produces the canonical
Windows installer and is the source of truth for arch-specific flags.

## Code signing

### macOS (local development)

Ad-hoc (zero-cost, local only) — already covered above:

```bash
codesign --force --deep --sign - \
  --entitlements flutter/macos/Runner/Release.entitlements \
  -o runtime "$APP"
```

The entitlements file MUST include:

- `com.apple.security.cs.disable-library-validation` — required to load
  `libsodium.26.dylib` from Homebrew (different Team ID than the app)
- `com.apple.security.cs.allow-jit` — Flutter engine JIT
- `com.apple.security.cs.allow-unsigned-executable-memory` — same
- `com.apple.security.network.client` and `network.server` — peer connections
- `com.apple.security.device.audio-input` — audio sharing
- `com.apple.security.app-sandbox = false` — needs unrestricted access

Without `cs.disable-library-validation` the app launches, fails to load
libsodium, and exits silently.

### macOS (distribution — Developer ID + notarization)

Requires a paid Apple Developer ID Application certificate. Sign with the real
identity instead of `-`:

```bash
codesign --deep --force --options runtime \
  --sign "Developer ID Application: <Your Team Name> (<TEAMID>)" \
  --entitlements flutter/macos/Runner/Release.entitlements \
  "FerryDesk Remote.app"

# Notarize via notarytool
ditto -c -k --keepParent "FerryDesk Remote.app" FerryDesk-Remote.zip
xcrun notarytool submit FerryDesk-Remote.zip \
  --apple-id <apple-id> \
  --team-id <TEAMID> \
  --password <app-specific-password> \
  --wait
xcrun stapler staple "FerryDesk Remote.app"
```

### Windows

**No EV cert yet** — builds are unsigned for now. Users will see SmartScreen
warnings on first run; they have to click "More info" → "Run anyway". Procure
an EV code-signing cert before broad distribution.

## Smoke test

After installing the build:

1. Open the app — title bar / About should say **FerryDesk Remote**.
2. The chat-popup header shows the 9-digit ID formatted `XXX XXX XXX`,
   the temporary password, and the version.
3. The status indicator should turn green within a few seconds — that confirms
   the baked-in pub key matches the one running on `ferrydesk.com`.
4. From the operator dashboard (or another RustDesk client pointed at
   `ferrydesk.com`), connect to the 9-digit ID. Connection should succeed
   immediately with **no password prompt and no click-to-approve dialog** —
   that's the auto-accept patch (commit `bee0423`) doing its job.

## Gotchas — read this before debugging build failures

### Cargo hangs in `list_files` for ~10 minutes then never compiles
You created a `vcpkg` symlink inside the repo. Don't. The cargo workspace
fingerprint walker descends through symlinks and ends up listing every file in
the 1.5 GB vcpkg install tree. Keep `vcpkg` outside the repo and pass the path
via `VCPKG_ROOT`. Verify with:

```bash
ls -la vcpkg  # should be: No such file or directory
```

### Flutter build fails with `Undefined name 'SemanticsFlags'`
You're building against the wrong Flutter SDK. Check
`flutter/.dart_tool/package_config.json`:

```bash
grep -A1 '"name": "flutter"' flutter/.dart_tool/package_config.json
```

Must be `file:///Users/pasha/flutter-3.24.5/packages/flutter`. If it's
`/opt/homebrew/share/flutter/...`, then Homebrew flutter took over during
`pub get`. Fix by hiding `/opt/homebrew/bin` from PATH and re-running pub get
with `flutter-3.24.5/bin/flutter` as the absolute first PATH entry. The
`env -i` form in the build commands above does this.

### Codesign fails: "resource fork, Finder information, or similar detritus"
Extended attributes from `cp` or iCloud sync are stuck in the bundle. Run
`xattr -cr "$APP"` before each codesign attempt. The xcconfig already disables
xcodebuild's automatic codesign step (`CODE_SIGNING_ALLOWED = NO` in
`flutter/macos/Runner/Configs/Release.xcconfig`) so signing is fully manual.

### Codesign fails: "code has no resources but signature indicates they must be present"
A previous codesign attempt left a malformed signature. Run
`codesign --remove-signature "$APP"` first, then re-sign.

### App launches but exits silently on Mac
Check `Console.app` for "code signature in (...) not valid for use" — usually
means libsodium loading was blocked. Add
`com.apple.security.cs.disable-library-validation` to entitlements and re-sign.

### CocoaPods reports "Pod install failed" but no obvious error
You're using system Ruby 2.6 which is broken with current CocoaPods. Install
Homebrew Ruby and put it first on PATH:

```bash
brew install ruby
export PATH="/opt/homebrew/opt/ruby/bin:/Users/pasha/.gem/ruby/4.0.0/bin:$PATH"
gem install cocoapods
```

### `flutter_rust_bridge_codegen` produces output cargo can't compile
The codegen version must match `flutter_rust_bridge = "=1.80"` in `Cargo.toml`.
Install the matching version:

```bash
cargo install flutter_rust_bridge_codegen --version 1.80.1 --force
```

If you ran codegen mid-build, the bridge files may be inconsistent — kill the
build, regenerate, and rebuild from clean:

```bash
~/.cargo/bin/flutter_rust_bridge_codegen \
  --rust-input ./src/flutter_ffi.rs \
  --dart-output ./flutter/lib/generated_bridge.dart \
  --c-output ./flutter/macos/Runner/bridge_generated.h \
  --class-name Rustdesk
cargo clean -p rustdesk
cargo build --features flutter --release --lib --bin service
```

## What's NOT branded yet (future work)

- App icon (still RustDesk's icon)
- In-app strings inside dialogs/menus (e.g. "RustDesk Settings") — there are
  dozens of these in the Flutter UI; full sweep deferred.
- Cargo package name (`rustdesk`), binary filenames (`rustdesk.exe`,
  `librustdesk.dll`), service name — internal identifiers, breaking changes.
- iOS / Android — out of scope; only Win + Mac targets for now.
- Auto-update server URL (RustDesk's update check still points at upstream).
- Menu-bar tray icon on macOS (NSStatusItem) — wired locally but reverted in
  upstream master; re-add when needed.

These are tracked for a "deeper rebrand" pass when needed.
