/// Snapshot-based undo/redo. Documents are small value types, so storing whole
/// states is simpler and safer than writing inverse operations.
public struct EditHistory<State: Equatable & Sendable>: Sendable {
    public struct Entry: Sendable {
        public var state: State
        public var name: String
    }

    private var past: [Entry] = []
    private var future: [Entry] = []
    public private(set) var current: State
    private var currentName = ""
    public var limit = 200

    public init(initial: State) { current = initial }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var undoName: String? { canUndo ? currentName : nil }
    public var redoName: String? { future.last?.name }

    /// Records a new state. Consecutive commits with the same `coalesceKey` merge (e.g. slider drags).
    public mutating func commit(_ state: State, name: String, coalesce: Bool = false) {
        guard state != current else { return }
        if coalesce, name == currentName, !past.isEmpty {
            current = state
            future.removeAll()
            return
        }
        past.append(Entry(state: current, name: currentName))
        if past.count > limit { past.removeFirst(past.count - limit) }
        current = state
        currentName = name
        future.removeAll()
    }

    public mutating func undo() -> State? {
        guard let prev = past.popLast() else { return nil }
        future.append(Entry(state: current, name: currentName))
        current = prev.state
        currentName = prev.name
        return current
    }

    public mutating func redo() -> State? {
        guard let next = future.popLast() else { return nil }
        past.append(Entry(state: current, name: currentName))
        current = next.state
        currentName = next.name
        return current
    }

    /// Replaces the current state without creating an undo step (e.g. loading).
    public mutating func reset(_ state: State) {
        current = state
        past.removeAll()
        future.removeAll()
    }
}
