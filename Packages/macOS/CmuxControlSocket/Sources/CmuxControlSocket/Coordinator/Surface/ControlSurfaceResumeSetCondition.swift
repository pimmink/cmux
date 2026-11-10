internal import Foundation

/// An optional atomic expectation for `surface.resume.set`.
public enum ControlSurfaceResumeSetCondition: Sendable, Equatable {
    case unbound
    case binding(checkpointID: String, source: String, updatedAt: Double)

    /// Compares identity fields as exact UTF-8 bytes, not canonical equivalents.
    /// A nil timestamp on the current authoritative binding
    /// denotes no binding, not a binding whose optional identity fields are nil.
    public func matches(checkpointID: String?, source: String?, updatedAt: Double?) -> Bool {
        switch self {
        case .unbound:
            return updatedAt == nil
        case .binding(let expectedCheckpointID, let expectedSource, let expectedUpdatedAt):
            guard let checkpointID, let source else { return false }
            return expectedUpdatedAt.isFinite
                && checkpointID.utf8.elementsEqual(expectedCheckpointID.utf8)
                && source.utf8.elementsEqual(expectedSource.utf8)
                && updatedAt == expectedUpdatedAt
        }
    }

    /// Parse without normalizing identity bytes or treating malformed guards as
    /// absent. In particular, JSON booleans are not numeric timestamps.
    static func parse(_ params: [String: JSONValue]) throws -> Self? {
        let identityKeys = ["if_checkpoint_id", "if_source", "if_updated_at"]
        let hasIdentity = identityKeys.contains { params[$0] != nil }
        if let unbound = params["if_unbound"] {
            guard unbound == .bool(true), !hasIdentity else { throw InvalidCondition.malformed }
            return .unbound
        }
        guard hasIdentity else { return nil }
        guard case .string(let checkpointID) = params["if_checkpoint_id"],
              !checkpointID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .string(let source) = params["if_source"],
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = params["if_updated_at"] else {
            throw InvalidCondition.malformed
        }
        let updatedAt: Double
        switch value {
        case .int(let number): updatedAt = Double(number)
        case .double(let number): updatedAt = number
        case .decimal(let number):
            guard let parsed = Double(number) else { throw InvalidCondition.malformed }
            updatedAt = parsed
        default: throw InvalidCondition.malformed
        }
        guard updatedAt.isFinite else { throw InvalidCondition.malformed }
        return .binding(checkpointID: checkpointID, source: source, updatedAt: updatedAt)
    }

    private enum InvalidCondition: Error {
        case malformed
    }
}
