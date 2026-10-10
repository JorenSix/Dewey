import AppKit
import FlyCore
import FlyBehavior

/// Steps every fly together (v4). Each tick it snapshots every controller's `flockSelf` first, hands each
/// fly the others' snapshots as `neighbors` (so the order of updates does not matter), and then updates all
/// controllers with the same pointer and dt. The boids rules themselves live in `FlyController` (module L)
/// and reach the brain only through the Percept's flock fields.
@MainActor
final class FlockCoordinator {
    /// Updates the flock and returns one frame per controller, in order.
    func step(_ controllers: [FlyController], pointer: CGPoint, dt: Double) -> [FlyFrame] {
        assignNeighbors(controllers)
        return controllers.map { $0.update(pointer: pointer, dt: dt) }
    }

    /// Sets `neighbors` on every controller from the others' `flockSelf` (taken before any update).
    func assignNeighbors(_ controllers: [FlyController]) {
        let selves = controllers.map(\.flockSelf)
        for (i, c) in controllers.enumerated() {
            var n: [FlockNeighbor] = []
            n.reserveCapacity(selves.count - 1)
            for (j, s) in selves.enumerated() where j != i { n.append(s) }
            c.neighbors = n
        }
    }
}
