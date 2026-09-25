import Foundation

/// Provider metadata orders speech messages; text never determines turn identity.
public struct SpeechTurnIdentity {
    private let session: UUID
    private var lastSequence = -1
    private var latestTurn = -1
    public init(session: UUID = UUID()) { self.session = session }

    public mutating func accept(sequence: Int?, turn: Int) -> String? {
        guard turn >= latestTurn else { return nil }
        if let sequence {
            guard sequence > lastSequence else { return nil }
            lastSequence = sequence
        }
        latestTurn = turn
        return "\(session.uuidString):\(turn)"
    }
}
