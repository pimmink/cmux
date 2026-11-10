import AppKit
import CMUXAgentLaunch
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #13369: `surface.resume.set` over the control socket
/// ran `NSAlert.runModal()` inside the command's main-actor job whenever the
/// proposed command had no approval record. The modal parked the command
/// coordinator, the socket stopped answering, and new clients saw EPIPE.
///
/// A socket request must not present approval UI. It stores the binding without
/// resume trust and reports `approval_required`, so the caller learns that a
/// person has to approve the command in the app.
///
/// The test host never presents the modal (the approval gate refuses under
/// XCTest), so these tests assert the reply the socket path returns instead of
/// observing the modal itself.
@MainActor
@Suite(.serialized)
struct SurfaceResumeSocketApprovalTests {
    @Test
    func socketResumeSetReportsApprovalRequiredForUnapprovedCommand() async throws {
        await Self.waitForSigningSecret()
        try withRegisteredWindow { windowID, workspace, panelID in
            // A command no approval record can match, so it needs a decision.
            let command = "cmux-issue-13369-probe --session \(UUID().uuidString.lowercased())"

            let result = try v2Result(method: "surface.resume.set", params: [
                "window_id": windowID.uuidString,
                "surface_id": panelID.uuidString,
                "command": command,
                "cwd": "/tmp/cmux-issue-13369",
            ])

            #expect(result["approval_required"] as? Bool == true)
            let binding = try #require(result["resume_binding"] as? [String: Any])
            #expect(binding["command"] as? String == command)
            #expect(binding["auto_resume"] as? Bool == false)

            let stored = try #require(workspace.surfaceResumeBinding(panelId: panelID))
            #expect(stored.command == command)
            #expect(stored.approvalRecordId == nil)
            #expect(!stored.allowsAutomaticResume)
        }
    }

    @Test
    func socketResumeSetReportsNoApprovalRequiredForTrustedAgentHook() async throws {
        await Self.waitForSigningSecret()
        try withRegisteredWindow { windowID, workspace, panelID in
            let sessionID = UUID().uuidString.lowercased()

            let result = try v2Result(method: "surface.resume.set", params: [
                "window_id": windowID.uuidString,
                "surface_id": panelID.uuidString,
                "command": "codex resume \(sessionID)",
                "checkpoint_id": sessionID,
                "source": "agent-hook",
                "auto_resume": true,
            ])

            #expect(result["approval_required"] as? Bool == false)
            #expect(workspace.surfaceResumeBinding(panelId: panelID)?.allowsAutomaticResume == true)
        }
    }

    @Test
    func ordinaryProposalMenuOffersExactReviewWithoutRewritingBinding() async throws {
        await Self.waitForSigningSecret()
        try withRegisteredWindow { _, workspace, panelID in
            let sessionID = UUID().uuidString.lowercased()
            let proposal = SurfaceResumeBindingSnapshot(
                name: "Review exact proposal",
                kind: "pi",
                command: "pi --session \(sessionID)",
                cwd: "/tmp/cmux-exact-review",
                checkpointId: sessionID,
                source: "example-resume-integration",
                environment: ["AUTH": "synthetic-epoch", "TICKET": "synthetic-ticket"],
                autoResume: false,
                updatedAt: 123
            )
            #expect(workspace.setSurfaceResumeBinding(proposal, panelId: panelID))
            let panel = try #require(workspace.focusedTerminalPanel)
            #expect(panel.id == panelID)
            let view = panel.hostedView.surfaceView
            let menu = NSMenu()
            #expect(view.appendCurrentSurfaceResumeMenuItems(to: menu))
            let submenu = try #require(menu.items.first?.submenu)
            // String lookup lets the regression compile before the action exists.
            // Assert the produced menu, not a source snippet or localized label.
            let review = try #require(submenu.items.first {
                $0.action == NSSelectorFromString("reviewCurrentSurfaceResumeApproval:")
            })
            #expect(review.target === view)
            #expect(review.isEnabled)
            #expect(workspace.surfaceResumeBinding(panelId: panelID) == proposal)
        }
    }

    @Test
    func menuOmitsReviewForBindingThatCannotBeApproved() async throws {
        await Self.waitForSigningSecret()
        try withRegisteredWindow { _, workspace, panelID in
            let proposal = SurfaceResumeBindingSnapshot(
                command: "pi --session synthetic",
                source: "process-detected"
            )
            #expect(workspace.setSurfaceResumeBinding(proposal, panelId: panelID))
            let view = try #require(workspace.focusedTerminalPanel).hostedView.surfaceView
            let menu = NSMenu()
            #expect(view.appendCurrentSurfaceResumeMenuItems(to: menu))
            let submenu = try #require(menu.items.first?.submenu)
            #expect(!submenu.items.contains {
                $0.action == NSSelectorFromString("reviewCurrentSurfaceResumeApproval:")
            })
        }
    }

    @Test
    func explicitReviewDoesNotRewriteProposalWhenTestHostCannotPrompt() async throws {
        await Self.waitForSigningSecret()
        try withRegisteredWindow { _, workspace, panelID in
            let proposal = SurfaceResumeBindingSnapshot(
                name: "Review exact proposal",
                kind: "pi",
                command: "pi --session \(UUID().uuidString.lowercased())",
                cwd: "/tmp/cmux-exact-review",
                checkpointId: UUID().uuidString.lowercased(),
                source: "pi-yolo-cmux-session-restore",
                environment: ["AUTH": "synthetic-epoch", "TICKET": "synthetic-ticket"],
                permissionMode: "default",
                autoResume: false,
                updatedAt: 123
            )
            #expect(workspace.setSurfaceResumeBinding(proposal, panelId: panelID))
            let result = TerminalController.shared.reviewSurfaceResumeBindingFromUserInterface(
                routing: ControlRoutingSelectors(
                    hasWindowIDParam: false, windowID: nil, groupID: nil,
                    workspaceID: workspace.id, surfaceID: panelID, paneID: nil
                ),
                explicitTargetID: panelID
            )
            // The native host's XCTest guard prohibits a modal and must not
            // manufacture consent or turn the proposal into a manual command.
            if case .setFailed = result { } else {
                Issue.record("A review with no native user decision must fail closed")
            }
            #expect(workspace.surfaceResumeBinding(panelId: panelID) == proposal)
        }
    }

    @Test(arguments: ["cli", "session-import", "process-detected", "agent-hook"])
    func explicitReviewCannotPromoteNonReviewableSources(source: String) {
        let proposal = SurfaceResumeBindingSnapshot(command: "pi --session synthetic", source: source)
        #expect(!SurfaceResumeApprovalStore.proposalAllowsUserApproval(binding: proposal))
    }

    @Test
    func approvalPromptDetailsShowSignedEnvironment() {
        let proposal = SurfaceResumeBindingSnapshot(
            command: "pi --session synthetic",
            source: "example-resume-integration",
            environment: ["ZDOTDIR": "/tmp/synthetic dir", "EXAMPLE_RESTORE_EPOCH": "synthetic-epoch"]
        )
        let details = SurfaceResumeApprovalStore.approvalPromptDetails(
            binding: proposal,
            environmentLabel: "Environment:"
        )
        #expect(details == """
        pi --session synthetic

        Environment:
        EXAMPLE_RESTORE_EPOCH=synthetic-epoch
        ZDOTDIR='/tmp/synthetic dir'
        """)
        let bare = SurfaceResumeBindingSnapshot(command: "pi --session synthetic", source: "manual")
        #expect(SurfaceResumeApprovalStore.approvalPromptDetails(
            binding: bare,
            environmentLabel: "Environment:"
        ) == "pi --session synthetic")
    }

    @Test
    func explicitReviewRefusesUnshownLaunchCommand() {
        var proposal = SurfaceResumeBindingSnapshot(
            command: "pi --session synthetic",
            source: "example-resume-integration"
        )
        #expect(SurfaceResumeApprovalStore.proposalAllowsExplicitReview(binding: proposal))
        proposal.launchCommand = AgentLaunchCommandSnapshot(
            launcher: "pi",
            executablePath: "/usr/local/bin/pi",
            arguments: ["/usr/local/bin/pi", "--session", "synthetic"],
            workingDirectory: nil,
            environment: nil
        )
        #expect(!SurfaceResumeApprovalStore.proposalAllowsExplicitReview(binding: proposal))
    }

    @Test
    func exactReviewAcceptsOrdinaryProposalButNotShellControl() {
        let proposal = SurfaceResumeBindingSnapshot(command: "pi --session synthetic", source: "pi-yolo-cmux-session-restore")
        #expect(SurfaceResumeApprovalStore.proposalAllowsUserApproval(binding: proposal))
        var unsafe = proposal
        unsafe.command = "pi --session synthetic; unexpected-command"
        #expect(!SurfaceResumeApprovalStore.proposalAllowsUserApproval(binding: unsafe))
    }

    // MARK: - Harness

    @Test
    func conditionalSetRequiresAbsenceAndPreservesLegacyReplacement() async throws {
        await Self.waitForSigningSecret()
        let capabilities = try v2Result(method: "system.capabilities", params: [:])
        let methods = capabilities["methods"] as? [String]
        #expect(methods?.contains("surface.resume.conditional_set.v1") == true)
        try withRegisteredWindow { windowID, workspace, panelID in
            var params: [String: Any] = [
                "window_id": windowID.uuidString, "surface_id": panelID.uuidString,
                "command": "vault-cas-initial", "source": "gsd",
                "checkpoint_id": "checkpoint", "if_unbound": true,
            ]
            #expect(workspace.surfaceResumeBinding(panelId: panelID) == nil)
            _ = try v2Result(method: "surface.resume.set", params: params)
            let initial = try #require(workspace.surfaceResumeBinding(panelId: panelID))
            params["command"] = "vault-cas-rejected"
            let rejected = try v2Envelope(method: "surface.resume.set", params: params)
            #expect(rejected["ok"] as? Bool == false)
            #expect((rejected["error"] as? [String: Any])?["code"] as? String == "binding_conflict")
            #expect(workspace.surfaceResumeBinding(panelId: panelID) == initial)
            params.removeValue(forKey: "if_unbound")
            params["command"] = "vault-cas-legacy"
            _ = try v2Result(method: "surface.resume.set", params: params)
            #expect(workspace.surfaceResumeBinding(panelId: panelID)?.command == "vault-cas-legacy")
        }
    }

    @Test(arguments: [
        "generation", "source", "checkpoint", "absence",
        "checkpoint-nfc", "checkpoint-nfd", "source-nfc", "source-nfd",
    ])
    func conditionalSetPreservesWriterThatChangedBindingAfterShow(field: String) async throws {
        await Self.waitForSigningSecret()
        try withRegisteredWindow { windowID, workspace, panelID in
            let target: [String: Any] = [
                "window_id": windowID.uuidString, "surface_id": panelID.uuidString,
            ]
            var params = target
            let nfc = "caf\u{00E9}"
            let nfd = "cafe\u{0301}"
            let expected = field.hasSuffix("nfc") ? nfd : nfc
            let actual = field.hasSuffix("nfc") ? nfc : nfd
            params["command"] = "vault-cas-old"
            params["checkpoint_id"] = field.hasPrefix("checkpoint-") ? expected : "checkpoint"
            params["source"] = field.hasPrefix("source-") ? expected : "gsd"
            _ = try v2Result(method: "surface.resume.set", params: params)
            let shown = try v2Result(method: "surface.resume.get", params: target)
            let observed = try #require(shown["resume_binding"] as? [String: Any])
            let old = try #require(workspace.surfaceResumeBinding(panelId: panelID))

            // A real model mutation occurs after the caller's show and before
            // its set. Isolate each guard component; source/checkpoint changes
            // deliberately retain the timestamp so a timestamp-only fence fails.
            if field == "absence" {
                _ = try v2Result(method: "surface.resume.clear", params: target)
            } else {
                var replacement = old
                replacement.command = "vault-cas-foreign"
                if field == "generation" { replacement.updatedAt += 1 }
                if field == "source" { replacement.source = "manual" }
                if field == "checkpoint" { replacement.checkpointId = "foreign-checkpoint" }
                if field.hasPrefix("checkpoint-") || field.hasPrefix("source-") {
                    if field.hasPrefix("checkpoint-") { replacement.checkpointId = actual }
                    if field.hasPrefix("source-") { replacement.source = actual }
                    let oldIdentity = try #require(field.hasPrefix("checkpoint-") ? old.checkpointId : old.source)
                    #expect(oldIdentity == actual)
                    #expect(!oldIdentity.utf8.elementsEqual(actual.utf8))
                    #expect(replacement.updatedAt == old.updatedAt)
                }
                #expect(workspace.setSurfaceResumeBinding(replacement, panelId: panelID))
            }
            let winner = workspace.surfaceResumeBinding(panelId: panelID)
            if field.hasPrefix("checkpoint-") || field.hasPrefix("source-") {
                let shownTimestamp = try #require(observed["updated_at"] as? Double)
                #expect(winner?.updatedAt == shownTimestamp)
            }
            params["command"] = "vault-cas-stale"
            params["if_checkpoint_id"] = try #require(observed["checkpoint_id"] as? String)
            params["if_source"] = try #require(observed["source"] as? String)
            params["if_updated_at"] = try #require(observed["updated_at"] as? Double)
            let rejected = try v2Envelope(method: "surface.resume.set", params: params)
            #expect(rejected["ok"] as? Bool == false)
            #expect((rejected["error"] as? [String: Any])?["code"] as? String == "binding_conflict")
            #expect(workspace.surfaceResumeBinding(panelId: panelID) == winner)
        }
    }

    @Test
    func conditionalSetReplacesExactlyObservedGeneration() async throws {
        await Self.waitForSigningSecret()
        try withRegisteredWindow { windowID, workspace, panelID in
            var params: [String: Any] = [
                "window_id": windowID.uuidString, "surface_id": panelID.uuidString,
                "command": "vault-cas-before", "source": "gsd", "checkpoint_id": "checkpoint",
            ]
            _ = try v2Result(method: "surface.resume.set", params: params)
            let shown = try v2Result(method: "surface.resume.get", params: params)
            let observed = try #require(shown["resume_binding"] as? [String: Any])
            params["if_checkpoint_id"] = try #require(observed["checkpoint_id"] as? String)
            params["if_source"] = try #require(observed["source"] as? String)
            params["if_updated_at"] = try #require(observed["updated_at"] as? Double)
            params["command"] = "vault-cas-after"
            _ = try v2Result(method: "surface.resume.set", params: params)
            #expect(workspace.surfaceResumeBinding(panelId: panelID)?.command == "vault-cas-after")
        }
    }

    private static func waitForSigningSecret() async {
        await withCheckedContinuation { continuation in
            SurfaceResumeApprovalStore.whenSigningSecretReady {
                continuation.resume()
            }
        }
    }

    private func withRegisteredWindow(
        _ body: (UUID, Workspace, UUID) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        try body(windowID, workspace, panel.id)
    }

    private func v2Envelope(method: String, params: [String: Any]) throws -> [String: Any] {
        let request = ["id": method, "method": method, "params": params] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: data, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func v2Result(method: String, params: [String: Any]) throws -> [String: Any] {
        let envelope = try v2Envelope(method: method, params: params)
        #expect(envelope["ok"] as? Bool == true, Comment(rawValue: String(describing: envelope)))
        return try #require(envelope["result"] as? [String: Any])
    }
}
