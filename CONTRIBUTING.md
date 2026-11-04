# Contributing

Use macOS 14 or later and a Swift 6 toolchain (Xcode/Command Line Tools). The app
has no third-party runtime dependencies. Python 3 is used only for helper checks
and the experimental SSH bridge.

Before submitting changes:

```sh
xcrun swift-format format --in-place --recursive Sources Tests
xcrun swift-format format --in-place Package.swift scripts/make-icon.swift
swift run --build-system native TurnStyleChecks
zsh scripts/build.sh
python3 scripts/check-helper.py
python3 scripts/check-codex-helper.py
python3 scripts/check-remote-bridge.py
```

The checks use temporary fixtures, not live provider configuration. Verify native
UI changes manually in light/dark modes and wide/narrow windows. Preserve keyboard
and accessibility labels, saved column order/widths, and independent user choices.

Keep provider adapters read-only except for explicit hook installation/removal.
Never log raw hook payloads or add live personal session fixtures. Keep scratch
files, screenshots, queue data, settings backups and handoff notes out of commits.

`Package.swift` exposes a dependency-free executable check runner rather than an
XCTest target, for compatibility with the original Command Line Tools setup. The
native build flag is retained for that toolchain; newer SwiftPM versions may warn
that it is deprecated.

For a clean source-only release candidate, run:

```sh
python3 scripts/export-source.py /path/to/new/TurnSTYLE-source
```

The destination must not exist. The exporter uses an explicit source/documentation
allowlist and excludes builds, screenshots, personal handoff notes, scratch data
and Python caches. Review that destination before creating a public repository.

Packaging keeps compiler caches under `~/Library/Caches/TurnSTYLE/SwiftPM`
(overridable with `TURNSTYLE_BUILD_CACHE`) and stages the bundle under `/private/tmp`
before signing, so the source
can live on a mounted filesystem. The generated architecture-specific app ZIP is
the portable binary artifact, and helper checks extract it onto local storage; never sign a modified/extracted app in place on a
mounted filesystem. Verify release archives after extracting onto local storage.

When running the core checks from a mounted filesystem, put SwiftPM's scratch
files on a local disk as well, for example:

```sh
swift run --build-system native --scratch-path /private/tmp/turnstyle-checks TurnStyleChecks
```
