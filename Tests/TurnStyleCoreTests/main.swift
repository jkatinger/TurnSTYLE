import Foundation

// A dependency-free runner: the installed Command Line Tools SDK lacks XCTest.
// Every check uses isolated temporary storage and no live Claude configuration.
var failures = 0
func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    failures += 1
    print("FAIL \(file):\(line) \(message)")
}
func assertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try !value() { fail("Expected true", file: file, line: line) }
}
func assertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line)
    rethrows
{
    if try value() { fail("Expected false", file: file, line: line) }
}
func assertEqual<T: Equatable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    if try a() != b() { fail("Values differ", file: file, line: line) }
}
func assertNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try value() != nil { fail("Expected nil", file: file, line: line) }
}
func assertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value == nil { fail("Expected a value", file: file, line: line) }
}
func unwrap<T>(_ value: T?) throws -> T {
    guard let value else {
        throw NSError(domain: "TurnStyleChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected a value"])
    }
    return value
}
func assertThrowsError<T>(
    _ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line
) {
    do {
        _ = try expression()
        fail("Expected an error", file: file, line: line)
    } catch {}
}

let checks: [(String, (TurnStyleCoreTests) throws -> Void)] = [
    (
        "Damaged inbox files are isolated; symlinks ignored",
        { try $0.testInboxQuarantinesInvalidFilesAndDoesNotFollowLinks() }
    ),
    ("Event IDs cannot escape the inbox", { try $0.testEventIDsCannotEscapeInbox() }),
    ("Invalid column preferences fall back safely", { $0.testColumnWidthsRejectInvalidPreferences() }),
    ("Unknown provider hook schemas survive uninstall", { try $0.testUninstallPreservesUnknownHookSchemas() }),
    (
        "Active queue retains chats across running/review transitions",
        { $0.testActiveQueueKeepsRunningAndReadyTogether() }
    ),
    (
        "Global search covers every status; indefinite snooze persists until resumed",
        { try $0.testGlobalSearchAndIndefiniteSnooze() }
    ),
    (
        "Claude local commands excluded, real later conversation retained",
        { try $0.testClaudeLocalCommandsAreNotChats() }
    ),
    (
        "Background Claude SDK jobs excluded from hooks, queue, reminders and history",
        { try $0.testBackgroundClaudeRunsExcluded() }
    ),
    (
        "Claude links map hook IDs to exact native Desktop sessions read-only",
        { try $0.testClaudeDesktopLinksUseNativeSessionID() }
    ),
    (
        "One-time archive keeps five, restores on resume and never limits future chats",
        { try $0.testInitialArchiveHasNoOngoingLimit() }
    ),
    (
        "Unified remote catalog preserves statuses, done and snooze",
        { $0.testUnifiedCatalogPreservesStatusAndUserChoices() }
    ),
    (
        "Codex connected-device catalog is read-only and host scoped",
        { try $0.testConnectedCodexCatalogIsReadOnlyAndHostScoped() }
    ),
    ("Codex chat links preserve remote host identity", { try $0.testCodexLinksPreserveConnectedHost() }),
    ("Remote Codex host isolation, replay, names and reconnect", { try $0.testRemoteCodexHostIsolationAndReplay() }),
    ("Remote history preserves host and begins at Check status", { try $0.testRemoteHistoryStartsUnknown() }),
    ("Codex lifecycle, provider isolation and privacy", { try $0.testCodexLifecycleAndPrivacy() }),
    ("Codex hooks preserve existing hooks, config and exact backup", { try $0.testCodexHookMergeAndExactBackup() }),
    ("Codex renamed titles and safe local history", { try $0.testCodexNamesAndHistory() }),
    (
        "Claude titles follow renames, partial writes and replacement",
        { try $0.testClaudeTitlesFollowRenamesAndPartialWrites() }
    ),
    ("Claude title lookup handles large transcripts", { try $0.testClaudeTitlesFindMetadataInLargeTranscripts() }),
    ("working → review → working", { $0.testTurnMovesFromWorkingToReviewAndBack() }),
    ("done stays done until a new prompt", { $0.testDoneSurvivesLateNotificationsButNewPromptReopens() }),
    ("snooze expires and replies clear it", { $0.testSnoozeExpiresAndReplyClearsSnooze() }),
    ("parallel tools preserve pending approval", { $0.testUnrelatedToolDoesNotClearPendingApproval() }),
    ("duplicate and old events", { $0.testDuplicateAndOldEventsDoNotRegressState() }),
    ("restart invalidates running state", { $0.testRestartDoesNotClaimSavedRunningStateIsLive() }),
    ("blocked and oldest sort first", { $0.testBlockedAndOldestSortFirst() }),
    ("session open is not a running turn", { $0.testStartDoesNotClaimRunning() }),
    ("question event and subagent exclusion", { try $0.testProviderMapsQuestionAndIgnoresSubagent() }),
    ("private payload minimization", { try $0.testProviderDoesNotStoreToolInputOrAssistantText() }),
    ("durable inbox replay", { try $0.testInboxReplayAfterSaveIsIdempotent() }),
    ("persistent user choices", { try $0.testPersistencePreservesChoicesAndIgnoresRetiredFields() }),
    ("hook merge, backup, idempotence and removal", { try $0.testHookInstallPreservesSettingsAndIsIdempotent() }),
    ("malformed settings preserved", { try $0.testMalformedSettingsAreNeverOverwritten() }),
    ("disabled hooks respected", { try $0.testDisabledHooksAreRespected() }),
    ("history discovery and safe status", { try $0.testHistoryIsUnknownAndExcludesSubagents() }),
]
for (name, run) in checks {
    let before = failures
    do { try run(TurnStyleCoreTests()) } catch { fail("\(name): \(error)") }
    if before == failures { print("PASS \(name)") }
}
print("\(checks.count) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
