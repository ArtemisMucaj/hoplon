import Observation

/// The id under the pointer, held outside the view that draws the hover targets.
///
/// Hover written to `@State` re-renders the whole view that owns it, on every
/// pointer move. For the token chart that meant re-laying out the Swift Charts
/// plot and re-formatting every row's tooltips; for the calendar, rebuilding all
/// ~371 cells. Held in an `@Observable` instead, only the views whose `body`
/// *reads* `id` — the readout line, a row's highlight — are invalidated. The
/// chart and the grid only *write* it from hover handlers, which does not
/// subscribe them.
///
/// Writes are skipped when nothing changed: Observation notifies on every set,
/// equal value or not, and a continuous hover fires on each pixel moved.
@Observable
final class HoverTracker {
    private(set) var id: String?

    /// Set the hovered id, or clear it with `nil`.
    func set(_ new: String?) {
        if id != new { id = new }
    }

    /// The pointer left `leaving` — clear it, unless a neighbour already took over.
    func leave(_ leaving: String) {
        if id == leaving { id = nil }
    }
}
