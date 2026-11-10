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
