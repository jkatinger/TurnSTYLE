# Security and privacy

TurnSTYLE is a local, unsandboxed macOS utility. It runs with the current user's
filesystem permissions and reads supported Claude Code and Codex session metadata.
It does not approve tools, execute conversation instructions, or call model APIs.
The standard app does not start a network listener or poll remote hosts. Remote
chat names and links come from Codex's locally synced catalog; opening a chat
hands a provider-specific URL to its desktop app.

## Stored data

The queue and hook inbox live in `~/Library/Application Support/TurnSTYLE/` (or
`TURNSTYLE_DATA_DIR` when explicitly configured). Directories are owner-only and
files are owner-readable/writable. Titles, session IDs, workspace/transcript paths,
statuses and queue preferences can contain sensitive information. A title may
initially contain up to 100 characters from the first line of a prompt. Full hook
payloads, tool inputs/results and assistant responses are not stored. Bounded
transcript segments are read in memory to identify titles and session origin.

Malformed inbox files are preserved under `invalid-events/` and do not block valid
events. These files may contain sensitive data: do not attach them, your queue,
provider settings, transcripts or settings backups to public issues.

Hook installation merges only TurnSTYLE entries, retains exact settings backups,
and respects explicit hook disabling. Provider hook review/trust still applies.
Disconnect integrations before removing the app so stale helper commands do not
remain in provider settings. Backups may contain unrelated sensitive configuration;
keep them private.

## Trust boundaries and limitations

- This is not isolation from other processes running as the same user. Such
  processes can already read or alter the provider files and TurnSTYLE queue.
- Internal provider metadata schemas and deep-link routes can change. Imported
  history and remote catalog rows are not evidence of a live running turn.
- Missing hook delivery, crashes and sleep can cause stale status. Restart/wake
  reconciles saved Working entries to Check status until a new signal arrives.
- The optional SSH bridge sources are experimental and inactive in the standard
  app. They are not required for connected-device names/links. Do not deploy them
  as part of the normal installation. SSH code requires existing authentication
  and strict known-host validation; it does not bypass device authorization.
- Local builds are ad-hoc signed, without notarization or hardened runtime. Public
  binary distribution needs a separate signing/notarization release process.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting if enabled for the repository. If it
is unavailable, open a minimal issue asking for a private reporting channel; do not
post exploit details, credentials or personal session data publicly.
