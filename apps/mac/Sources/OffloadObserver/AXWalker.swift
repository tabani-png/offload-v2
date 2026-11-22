// The bounded Accessibility walk (ARCHITECTURE section 1): at most 1,500 nodes, depth 12 and 150 ms, secure text
// fields skipped with everything under them. Generic over a node protocol so tests walk a scripted tree.
import Foundation

public protocol AXNodeReading: AnyObject {
    /// The node's own visible text (value or title), if any.
    var text: String? { get }
    /// A secure text field: neither it nor its children are read.
    var isSecure: Bool { get }
    var children: [any AXNodeReading] { get }
}

public struct AXWalkLimits: Equatable, Sendable {
    public var maxNodes: Int
    public var maxDepth: Int
    public var budget: TimeInterval

    public init(maxNodes: Int, maxDepth: Int, budget: TimeInterval) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.budget = budget
    }

    public static let standard = AXWalkLimits(maxNodes: 1500, maxDepth: 12, budget: 0.150)
}

public enum AXWalkStop: Equatable, Sendable {
    case complete
    case nodes
    case depth
    case time
}

public struct AXWalkResult: Equatable, Sendable {
    public var text: String
    public var visitedNodes: Int
    /// The deepest level visited (the root is 0).
    public var deepest: Int
    public var stop: AXWalkStop

    public init(text: String, visitedNodes: Int, deepest: Int, stop: AXWalkStop) {
        self.text = text
        self.visitedNodes = visitedNodes
        self.deepest = deepest
        self.stop = stop
    }
}

public enum AXWalker {
    /// Depth-first, in reading order. `now` is a monotonic clock in seconds (a scripted one in tests).
    public static func walk(root: any AXNodeReading, limits: AXWalkLimits, now: () -> TimeInterval) -> AXWalkResult {
        let start = now()
        var lines: [String] = []
        var visited = 0
        var deepest = 0
        var stop = AXWalkStop.complete
        var stack: [(node: any AXNodeReading, depth: Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            if visited >= limits.maxNodes { stop = .nodes; break }
            if now() - start > limits.budget { stop = .time; break }
            if depth > limits.maxDepth {
                if stop == .complete { stop = .depth }
                continue
            }
            visited += 1
            deepest = max(deepest, depth)
            if node.isSecure { continue }
            if let text = node.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { lines.append(text) }
            for child in node.children.reversed() { stack.append((child, depth + 1)) }
        }
        return AXWalkResult(text: lines.joined(separator: "\n"), visitedNodes: visited, deepest: deepest, stop: stop)
    }
}
