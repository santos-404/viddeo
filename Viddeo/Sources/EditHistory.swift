import Foundation

/// Snapshot undo/redo stack. Mirrors the observed reference semantics: edits arriving within
/// the coalescing window under the same key become one step, a new edit after undo drops the
/// redo tail, and the history keeps at most `limit` undo steps. Time is passed in so the
/// history is deterministic.
struct EditHistory<State: Equatable & Sendable>: Sendable {
    let limit: Int
    let coalescingWindow: Double
    private var states: [State]
    private var index = 0
    private var lastKey: String?
    private var lastTime: Double?

    init(initial: State, limit: Int = 1000, coalescingWindow: Double = 0.1) {
        self.limit = max(1, limit)
        self.coalescingWindow = coalescingWindow.isFinite ? max(0, coalescingWindow) : 0
        states = [initial]
    }

    var state: State { states[index] }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < states.count - 1 }
    var undoDepth: Int { index }
    var redoDepth: Int { states.count - 1 - index }

    mutating func record(_ newState: State, coalescingKey: String? = nil, at time: Double) {
        guard newState != state else { return }
        if let coalescingKey, coalescingKey == lastKey, let lastTime, time.isFinite,
           time >= lastTime, time - lastTime <= coalescingWindow, canUndo, !canRedo {
            states[index] = newState
            self.lastTime = time
            // A coalesced gesture that returns to where it started is no step at all.
            if states[index] == states[index - 1] {
                states.removeLast()
                index -= 1
                resetCoalescing()
            }
            return
        }
        states.removeSubrange((index + 1)...)
        states.append(newState)
        index += 1
        if states.count - 1 > limit {
            states.removeFirst(states.count - 1 - limit)
            index = states.count - 1
        }
        lastKey = coalescingKey
        lastTime = time.isFinite ? time : nil
    }

    @discardableResult
    mutating func undo() -> State? {
        guard canUndo else { return nil }
        index -= 1
        resetCoalescing()
        return state
    }

    @discardableResult
    mutating func redo() -> State? {
        guard canRedo else { return nil }
        index += 1
        resetCoalescing()
        return state
    }

    private mutating func resetCoalescing() {
        lastKey = nil
        lastTime = nil
    }
}
