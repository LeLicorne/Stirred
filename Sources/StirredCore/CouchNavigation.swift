import Foundation

/// What a key or a controller button means in couch mode.
public enum CouchEvent: Sendable, Equatable { case left, right, select, back, stop }

/// What the screen should do after an event.
public enum CouchAction: Sendable, Equatable { case none, play(Int), stop(Int), exit }

/// Which game is highlighted in the one-row couch view. Pure logic, so keys and controllers behave the same.
public struct CouchSelection: Sendable, Equatable {
    public private(set) var index: Int
    public private(set) var count: Int

    public init(count: Int, index: Int = 0) {
        self.count = max(count, 0)
        self.index = self.count == 0 ? 0 : min(max(index, 0), self.count - 1)
    }

    /// The game list changed (a game was installed or removed): keep the highlight on a valid game.
    public mutating func update(count newCount: Int) { self = CouchSelection(count: newCount, index: index) }

    public mutating func apply(_ event: CouchEvent) -> CouchAction {
        switch event {
        case .left: index = max(index - 1, 0); return .none
        case .right: index = min(index + 1, max(count - 1, 0)); return .none
        case .select: return count == 0 ? .none : .play(index)
        case .stop: return count == 0 ? .none : .stop(index)
        case .back: return .exit
        }
    }
}

public enum StickMapper {
    /// A thumbstick pushed past `threshold` on one axis (the stronger one) counts as one press, like the D-pad.
    public static func event(x: Float, y: Float, threshold: Float = 0.6) -> CouchEvent? {
        guard abs(x) >= threshold, abs(x) > abs(y) else { return nil }
        return x < 0 ? .left : .right
    }
}
