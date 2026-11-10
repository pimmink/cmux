import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator surface resume conditional set")
struct ControlCommandCoordinatorSurfaceResumeConditionalSetTests {
    @Test(
        "malformed set conditions are rejected before mutation dispatch",
        arguments: [
            // Every nonempty proper subset of the replacement expectation is invalid.
            ["if_checkpoint_id": .string("old-checkpoint")],
            ["if_source": .string("gsd")],
            ["if_updated_at": .double(42.5)],
            ["if_checkpoint_id": .string("old-checkpoint"), "if_source": .string("gsd")],
            ["if_checkpoint_id": .string("old-checkpoint"), "if_updated_at": .double(42.5)],
            ["if_source": .string("gsd"), "if_updated_at": .double(42.5)],
            // Absence and replacement expectations must never be combined.
            ["if_unbound": .bool(true), "if_checkpoint_id": .string("old-checkpoint")],
            ["if_unbound": .bool(true), "if_source": .string("gsd")],
            ["if_unbound": .bool(true), "if_updated_at": .double(42.5)],
            [
                "if_unbound": .bool(true),
                "if_checkpoint_id": .string("old-checkpoint"),
                "if_source": .string("gsd"),
                "if_updated_at": .double(42.5),
            ],
            // A present-but-invalid absence guard must not become an unguarded write.
            ["if_unbound": .bool(false)],
            ["if_unbound": .null],
            ["if_unbound": .int(1)],
            ["if_unbound": .string("true")],
            ["if_unbound": .array([])],
            ["if_unbound": .object([:])],
            // All replacement identity fields must be typed, nonempty values.
            [
                "if_checkpoint_id": .null,
                "if_source": .string("gsd"),
                "if_updated_at": .double(42.5),
            ],
            [
                "if_checkpoint_id": .string(" \n "),
                "if_source": .string("gsd"),
                "if_updated_at": .double(42.5),
            ],
            [
                "if_checkpoint_id": .int(1),
                "if_source": .string("gsd"),
                "if_updated_at": .double(42.5),
            ],
            [
                "if_checkpoint_id": .string("old-checkpoint"),
                "if_source": .null,
                "if_updated_at": .double(42.5),
            ],
            [
                "if_checkpoint_id": .string("old-checkpoint"),
                "if_source": .string(" \t "),
                "if_updated_at": .double(42.5),
            ],
            [
                "if_checkpoint_id": .string("old-checkpoint"),
                "if_source": .bool(true),
                "if_updated_at": .double(42.5),
            ],
            [
                "if_checkpoint_id": .string("old-checkpoint"),
                "if_source": .string("gsd"),
                "if_updated_at": .null,
            ],
            [
                "if_checkpoint_id": .string("old-checkpoint"),
                "if_source": .string("gsd"),
                "if_updated_at": .string("42.5"),
            ],
            [
                "if_checkpoint_id": .string("old-checkpoint"),
                "if_source": .string("gsd"),
                "if_updated_at": .bool(true),
            ],
            [
                "if_checkpoint_id": .string("old-checkpoint"),
                "if_source": .string("gsd"),
                "if_updated_at": .double(.nan),
            ],
            [
                "if_checkpoint_id": .string("old-checkpoint"),
                "if_source": .string("gsd"),
                "if_updated_at": .double(.infinity),
            ],
            [
                "if_checkpoint_id": .string("old-checkpoint"),
                "if_source": .string("gsd"),
                "if_updated_at": .double(-.infinity),
            ],
        ] as [[String: JSONValue]]
    )
    func surfaceResumeSetRejectsMalformedConditionsBeforeMutation(
        conditions: [String: JSONValue]
    ) {
        let context = makeContext()
        let coordinator = ControlCommandCoordinator(context: context)
        var params = conditions
        params["command"] = .string("gsd --resume-exact /fixture/session.jsonl session-id")
        params["source"] = .string("gsd")
        params["checkpoint_id"] = .string("/fixture/session.jsonl")

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.set",
            params: params
        ))

        if case .err(let code, _, _) = result {
            #expect(code == "invalid_params")
        } else {
            Issue.record("Malformed conditional set was accepted instead of returning invalid_params")
        }
        let mutationWasDispatched = context.resumeSetInputs != nil
        #expect(!mutationWasDispatched)
    }

    @Test func absenceConditionReachesMutationDispatch() {
        let context = makeContext()
        let coordinator = ControlCommandCoordinator(context: context)
        _ = coordinator.handle(ControlRequest(
            id: .int(1), method: "surface.resume.set",
            params: ["command": .string("resume"), "if_unbound": .bool(true)]
        ))
        #expect(context.resumeSetInputs?.condition == .unbound)
    }

    @Test(arguments: [JSONValue.int(42), .double(42), .decimal("42.0")])
    func replacementConditionRetainsExactIdentity(updatedAt: JSONValue) {
        let context = makeContext()
        let coordinator = ControlCommandCoordinator(context: context)
        _ = coordinator.handle(ControlRequest(
            id: .int(1), method: "surface.resume.set",
            params: [
                "command": .string("resume"),
                "if_checkpoint_id": .string(" /fixture/session.jsonl "),
                "if_source": .string("gsd"),
                "if_updated_at": updatedAt,
            ]
        ))
        #expect(context.resumeSetInputs?.condition == .binding(
            checkpointID: " /fixture/session.jsonl ", source: "gsd", updatedAt: 42
        ))
    }

    @Test func nativeConflictIsReportedWithoutSuccessPayload() {
        let context = makeContext()
        context.resumeResolution = .bindingConflict
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(
            id: .int(1), method: "surface.resume.set",
            params: ["command": .string("resume"), "if_unbound": .bool(true)]
        ))
        guard case .err(let code, _, _) = result else {
            Issue.record("Expected binding_conflict without a success payload")
            return
        }
        #expect(code == "binding_conflict")
    }

    @Test(arguments: ["generation", "source", "checkpoint", "absence"])
    func replacementConditionRejectsChangedBinding(field: String) {
        let condition = ControlSurfaceResumeSetCondition.binding(
            checkpointID: "checkpoint", source: "gsd", updatedAt: 42
        )
        #expect(condition.matches(checkpointID: "checkpoint", source: "gsd", updatedAt: 42))
        #expect(!condition.matches(
            checkpointID: field == "checkpoint" ? "replacement" : "checkpoint",
            source: field == "source" ? "manual" : "gsd",
            updatedAt: field == "absence" ? nil : (field == "generation" ? 43 : 42)
        ))
    }

    @Test(arguments: ["checkpoint-nfc", "checkpoint-nfd", "source-nfc", "source-nfd"])
    func replacementConditionRejectsCanonicallyEquivalentIdentity(field: String) {
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        #expect(nfc == nfd) // Swift String equality deliberately treats these as equivalent.
        #expect(!nfc.utf8.elementsEqual(nfd.utf8))
        let expected = field.hasSuffix("nfc") ? nfd : nfc
        let actual = field.hasSuffix("nfc") ? nfc : nfd
        let checkpoint = field.hasPrefix("checkpoint")
        let condition = ControlSurfaceResumeSetCondition.binding(
            checkpointID: checkpoint ? expected : "checkpoint",
            source: checkpoint ? "gsd" : expected,
            updatedAt: 42
        )
        #expect(!condition.matches(
            checkpointID: checkpoint ? actual : "checkpoint",
            source: checkpoint ? "gsd" : actual,
            updatedAt: 42
        ))
        #expect(condition.matches(
            checkpointID: checkpoint ? expected : "checkpoint",
            source: checkpoint ? "gsd" : expected,
            updatedAt: 42
        ))
    }

    @Test func absenceConditionRejectsAnyExistingBinding() {
        #expect(ControlSurfaceResumeSetCondition.unbound.matches(
            checkpointID: nil, source: nil, updatedAt: nil
        ))
        #expect(!ControlSurfaceResumeSetCondition.unbound.matches(
            checkpointID: nil, source: nil, updatedAt: 0
        ))
    }

    @Test func unguardedSetRetainsLegacyMutationDispatch() {
        let context = makeContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let command = "gsd --resume-exact /fixture/session.jsonl session-id"

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.set",
            params: ["command": .string(command), "source": .string("gsd")]
        ))

        guard case .ok = result else {
            Issue.record("Legacy unguarded set was rejected")
            return
        }
        #expect(context.resumeSetInputs?.command == command)
        #expect(context.resumeSetInputs?.condition == nil)
    }

    private func makeContext() -> FakeSurfaceControlCommandContext {
        let context = FakeSurfaceControlCommandContext()
        context.resumeResolution = .result(ControlSurfaceResumeSnapshot(
            windowID: nil,
            workspaceID: UUID(),
            paneID: nil,
            surfaceID: UUID(),
            cleared: false,
            binding: nil,
            restoreRecord: nil
        ))
        return context
    }
}
