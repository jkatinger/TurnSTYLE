# TurnSTYLE 0.4.2 beta

A free local queue for Claude Code and Codex chats. This is an early hobby-project
beta, released under the MIT license.

This candidate includes the compact, horizontally scrolling tables; source-colored
chat titles; neutral dark mode; global search; snoozing; and the optional Always on
top setting. It also includes the robustness fixes and source cleanup from the
pre-release QA pass.

## Downloads and setup

- Source: build with a Swift 6 toolchain on macOS. See README.md and CONTRIBUTING.md.
- The prebuilt macOS ZIP is Apple Silicon (arm64), ad-hoc signed and **not Apple
  notarized**. macOS may require explicit approval before opening a downloaded app.
- Move TurnSTYLE.app to a permanent location before connecting hooks. Review hook
  commands in your provider app when required.

## Known limits

- Local testing used Apple Silicon and macOS 26.7.2. The package targets macOS 14+;
  older macOS releases and Intel Macs have not been validated for this beta.
- Remote Codex chat names/links come from Codex's synced metadata; live remote turn
  status is unavailable. Local hooks supply local runtime status.
- Provider metadata and deep-link formats are internal and can change.
- No automatic updates, launch-at-login registration, model API calls or billing.
- Session titles and paths are private local data. See SECURITY.md before sharing
  diagnostics publicly.
