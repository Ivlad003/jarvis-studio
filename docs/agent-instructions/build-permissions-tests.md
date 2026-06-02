# Build, Signing, Permissions, and Tests

## Build Commands

Generate the Xcode project after cloning or adding files:

```sh
xcodegen generate
```

Primary workflow:

```sh
make install
make test
```

`make install` is preferred over manual `xcodebuild` for installed builds. It builds unsigned, signs after build, removes `/Applications/KosmoNotes.app`, and copies the fresh bundle.

## Toolchain

SwiftPM tests require Xcode's toolchain. The Makefile sets this:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Plain `swift test` with Command Line Tools may run zero tests.

## Signing

Installed development builds are signed with:

- Certificate: `Apple Development: Vladyslav Kosmach (7CP69K73N6)`
- Team: `Q7ZGRSDQSQ`
- Certificate hash: `700E6802C639969593A1AC7F57C1FBFA0A1C7762`

Signing happens after build because SPM dependencies use automatic signing settings that conflict with manual signing flags.

No notarization or auto-update exists for v1. Hand-shared binaries may need:

```sh
xattr -d com.apple.quarantine /Applications/KosmoNotes.app
```

## Permissions

`KosmoNotesApp.checkPermissionsOnStartup()` runs on launch.

- Screen Recording: use `CGPreflightScreenCaptureAccess()`.
- Microphone: request only when not determined.
- Accessibility: use the system prompt when not trusted.

Do not use `SCShareableContent.excludingDesktopWindows` as a Screen Recording TCC probe. On macOS 15+/26 it can throw `-3801 userDeclined` even when System Settings shows permission granted.

Screen recording failure must be non-fatal. Audio recording continues, and `RecorderState.screenRecordingWarning` surfaces the warning through the menu.

## Test Baseline

Last known passing baseline, 2026-05-25:

```sh
make test
# 293 tests in 60 suites passed
```

Focused app-test command used during recent fixes:

```sh
xcodebuild test -scheme KosmoNotes -destination 'platform=macOS' -only-testing:KosmoNotesTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
```

This passed 15 Swift Testing app tests.

`JN_RUN_PERF=1` enables the FTS5 performance benchmark.

## Generated Churn

Xcode's build phase stamps `App/Info.plist` `CFBundleVersion`. If a test/build changed only that value and the user did not ask for a version bump, revert the generated stamp before finalizing.
