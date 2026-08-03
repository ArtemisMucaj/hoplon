import SwiftUI
import Observation

/// A lightweight force-directed layout engine for `NamespaceGraphView`: a
/// Fruchterman-Reingold-style spring model (repulsion between nodes, spring
/// attraction along edges) with an added **community-clustering** force that
/// pulls same-community nodes toward their shared centroid — so the graph groups
/// tightly by color instead of scattering, and settles fast. Ticked on a timer;
/// positions live in a centered "world" space that the view maps to the viewport
/// with its own pan/zoom. Kept off the SwiftUI view so restarting the graph
/// doesn't lose the running simulation.
@Observable
final class GraphLayout {
    /// Current node positions in world space, indexed like `CodeGraph.nodes`.
    private(set) var positions: [CGPoint] = []

    /// True while the layout is still moving a lot (the first, energetic phase of
    /// the simulation). The view keeps a "stabilizing…" loader up while this is
    /// set so it reveals a mostly-settled graph instead of a wandering one.
    private(set) var isSettling = false

    private var velocities: [CGPoint] = []
    private var edges: [(Int, Int, Double)] = []
    private var communityOf: [Int] = []          // node index → community index
    private var communityAnchor: [Int: CGPoint] = [:]  // fixed sector center per community
    private var nodeCount = 0
    private var timer: Timer?
    private var iteration = 0

    // Simulation constants. A shorter run with a strong community force settles
    // faster and calmer than a long generic FR run.
    private let maxIterations = 150
    private let repulsion: Double = 3500
    private let repulsionCutoff: Double = 220     // skip repulsion beyond this — cheap + local
    private let springLength: Double = 55
    private let springStrength: Double = 0.018
    /// Pull toward the node's community centroid — the dominant grouping force.
    /// Strong, so same-community nodes clump into a visible island rather than
    /// spraying across the disc.
    private let communityStrength: Double = 0.13
    /// Pull each community centroid toward its fixed sector anchor, so clusters
    /// hold their own territory. Moderate — too strong flings everything to the
    /// rim and hollows out the center.
    private let anchorStrength: Double = 0.06
    private let gravity: Double = 0.012
    private let damping: Double = 0.82
    private let maxStep: Double = 24

    /// (Re)start the simulation for a graph. Seeds nodes on a circle (stable,
    /// deterministic — no RNG) so identical graphs lay out identically, then
    /// ticks until it settles or hits the iteration cap.
    func start(graph: CodeGraph, viewport: CGSize) {
        stop()
        nodeCount = graph.nodes.count
        iteration = 0
        guard nodeCount > 0 else { positions = []; velocities = []; isSettling = false; return }
        isSettling = true

        communityOf = graph.nodes.map(\.community)

        // Give each community a fixed sector around a ring, so clusters start —
        // and stay — spread apart. Nodes seed in a tight blob at their community
        // anchor, so same-color nodes begin close and barely have to migrate
        // (fast settle, little wandering).
        let comms = Array(Set(communityOf)).sorted()
        // Ring radius keyed to the viewport (not the community count — that
        // ballooned to thousands of px and hollowed out the center). Grows only
        // mildly with community count and is capped so the graph stays centered.
        let base = Double(min(viewport.width, viewport.height))
        let radius = min(base * 0.55,
                         base * 0.30 * (1 + log2(Double(max(2, comms.count))) / 12))
        communityAnchor = [:]
        for (k, c) in comms.enumerated() {
            let a = 2 * Double.pi * Double(k) / Double(max(1, comms.count))
            communityAnchor[c] = CGPoint(x: cos(a) * radius, y: sin(a) * radius)
        }
        // Deterministic per-node jitter inside a tight community blob (index-hashed,
        // no RNG) so nodes don't stack exactly and identical graphs reproduce.
        positions = (0..<nodeCount).map { i in
            let anchor = communityAnchor[communityOf[i]] ?? .zero
            let h = Double((i &* 2654435761) % 997) / 997.0
            let a = 2 * Double.pi * h
            let r = 8 + 18 * Double((i / 3) % 3)
            return CGPoint(x: anchor.x + CGFloat(cos(a) * r), y: anchor.y + CGFloat(sin(a) * r))
        }
        velocities = Array(repeating: .zero, count: nodeCount)
        edges = graph.edges
            .filter { $0.source < nodeCount && $0.target < nodeCount && $0.source != $0.target }
            .map { ($0.source, $0.target, max(0.1, $0.weight)) }

        // ~30fps ticks. Each tick advances the physics; the view redraws because
        // `positions` is observed.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isSettling = false
    }

    /// Iterations after which the layout is "mostly settled": past the energetic
    /// phase (quadratic cooling front-loads movement), so the view can reveal it.
    /// ~70% of the run at 30fps ≈ 3.5s — matches the intended stabilize-then-show.
    private var settledAfter: Int { (maxIterations * 7) / 10 }

    /// One physics step. Cools quickly (quadratic schedule) so the graph locks
    /// in after a short, calm run, then freezes at `maxIterations`.
    private func tick() {
        guard nodeCount > 0 else { stop(); return }
        iteration += 1
        // Quadratic cooling: most movement happens in the first ~third, then it
        // fine-tunes and freezes — far less late wandering than a linear decay.
        let progress = Double(iteration) / Double(maxIterations)
        let temp = maxStep * max(0.015, (1.0 - progress) * (1.0 - progress))

        var force = Array(repeating: CGPoint.zero, count: nodeCount)

        // Community centroids this step — the target every member is pulled to.
        var sum: [Int: CGPoint] = [:]
        var counts: [Int: Int] = [:]
        for i in 0..<nodeCount {
            let c = communityOf[i]
            sum[c, default: .zero].x += positions[i].x
            sum[c, default: .zero].y += positions[i].y
            counts[c, default: 0] += 1
        }
        var centroid: [Int: CGPoint] = [:]
        for (c, s) in sum {
            let n = CGFloat(max(1, counts[c] ?? 1))
            centroid[c] = CGPoint(x: s.x / n, y: s.y / n)
        }

        // Local repulsion with a distance cutoff. Beyond the cutoff a pair
        // contributes almost nothing, so instead of the O(n²) all-pairs loop
        // (which still *visits* every far pair just to skip it — 4M+ checks per
        // tick at a few thousand nodes) we bin nodes into a spatial hash grid
        // sized to the cutoff and only compare each node against its own and the
        // 8 neighbouring cells. That makes repulsion ~O(n) for a spread graph,
        // which is what actually settles a large namespace graph quickly.
        let cell = max(1.0, repulsionCutoff)
        var grid: [Int64: [Int]] = [:]
        grid.reserveCapacity(nodeCount)
        @inline(__always) func key(_ cx: Int, _ cy: Int) -> Int64 {
            (Int64(cx) << 32) ^ (Int64(cy) & 0xFFFF_FFFF)
        }
        let cellOf: [(Int, Int)] = (0..<nodeCount).map { i in
            (Int((Double(positions[i].x) / cell).rounded(.down)),
             Int((Double(positions[i].y) / cell).rounded(.down)))
        }
        for i in 0..<nodeCount { grid[key(cellOf[i].0, cellOf[i].1), default: []].append(i) }

        let cutoffSq = repulsionCutoff * repulsionCutoff
        for i in 0..<nodeCount {
            let (cx, cy) = cellOf[i]
            for ny in (cy - 1)...(cy + 1) {
                for nx in (cx - 1)...(cx + 1) {
                    guard let bucket = grid[key(nx, ny)] else { continue }
                    for j in bucket {
                        // Each unordered pair once: only act when j > i (both
                        // endpoints get the symmetric force below).
                        if j <= i { continue }
                        var dx = positions[i].x - positions[j].x
                        var dy = positions[i].y - positions[j].y
                        var distSq = Double(dx * dx + dy * dy)
                        if distSq > cutoffSq { continue }
                        if distSq < 0.01 { dx = 0.1; dy = 0.1; distSq = 0.02 }
                        let dist = distSq.squareRoot()
                        // Weaken repulsion between same-community nodes so they pack.
                        let sameComm = communityOf[i] == communityOf[j]
                        let rep = (repulsion / distSq) * (sameComm ? 0.35 : 1.0)
                        let fx = Double(dx) / dist * rep
                        let fy = Double(dy) / dist * rep
                        force[i].x += fx; force[i].y += fy
                        force[j].x -= fx; force[j].y -= fy
                    }
                }
            }
        }

        // Spring attraction along edges.
        for (a, b, w) in edges {
            let dx = Double(positions[b].x - positions[a].x)
            let dy = Double(positions[b].y - positions[a].y)
            let dist = max(0.01, (dx * dx + dy * dy).squareRoot())
            let disp = (dist - springLength) * springStrength * w
            let fx = dx / dist * disp
            let fy = dy / dist * disp
            force[a].x += fx; force[a].y += fy
            force[b].x -= fx; force[b].y -= fy
        }

        // Community clustering: pull each node toward its centroid (groups by
        // color), and pull each centroid toward its fixed sector anchor (keeps
        // communities spread around the ring rather than piling up centrally).
        for i in 0..<nodeCount {
            let c = communityOf[i]
            if let ctr = centroid[c] {
                force[i].x += (ctr.x - positions[i].x) * CGFloat(communityStrength)
                force[i].y += (ctr.y - positions[i].y) * CGFloat(communityStrength)
                if let anchor = communityAnchor[c] {
                    force[i].x += (anchor.x - ctr.x) * CGFloat(anchorStrength)
                    force[i].y += (anchor.y - ctr.y) * CGFloat(anchorStrength)
                }
            }
            // Mild centering gravity keeps the whole graph on-canvas.
            force[i].x -= positions[i].x * CGFloat(gravity)
            force[i].y -= positions[i].y * CGFloat(gravity)
        }

        // Integrate with velocity damping and a per-step cap at the temperature.
        for i in 0..<nodeCount {
            velocities[i].x = (velocities[i].x + force[i].x) * CGFloat(damping)
            velocities[i].y = (velocities[i].y + force[i].y) * CGFloat(damping)
            let vx = Double(velocities[i].x), vy = Double(velocities[i].y)
            let speed = max(0.0001, (vx * vx + vy * vy).squareRoot())
            let capped = min(speed, temp)
            positions[i].x += CGFloat(vx / speed * capped)
            positions[i].y += CGFloat(vy / speed * capped)
        }

        // Reveal the graph once past the energetic phase (keeps the sim running
        // for the calm fine-tuning, but drops the loader so the reveal is smooth).
        if isSettling && iteration >= settledAfter { isSettling = false }
        if iteration >= maxIterations { stop() }
    }

    deinit { stop() }
}
