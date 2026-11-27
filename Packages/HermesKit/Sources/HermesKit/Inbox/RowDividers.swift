import Foundation

/// The line under a list row (`docs/inbox.md` §10): a quiet line between the rows of one region, a
/// stronger one under a region's last row while anything follows it, and none under the list's
/// last row.
public enum SidebarRowDivider: Equatable, Sendable {
    case none
    case line
    case section
}

/// Where the line under each row of a regioned list goes. Give it the rows in order, grouped by
/// the line that ends each region, and it says each row's line: a `.line` between the rows of one
/// region, the region's boundary under its last row while anything follows, and `.none` under the
/// list's very last row.
///
/// The Chats list (Pinned and Main, Working, Settled) and the Bots list (group chats, pinned Bots,
/// hidden Bots) ask once and hand each row its answer, so no list counts indices in its
/// `ForEach` (`docs/inbox.md` §10).
public struct RowDividerPlan<ID: Hashable & Sendable>: Sendable {
    /// A run of rows that share one kind of line under their last row.
    public struct Region: Sendable {
        public var rows: [ID]
        /// The line under the region's last row while anything follows it: `.line` or `.section`.
        public var boundary: SidebarRowDivider

        public init(rows: [ID], boundary: SidebarRowDivider = .section) {
            self.rows = rows
            self.boundary = boundary
        }
    }

    public private(set) var regions: [Region] = []

    /// Something that isn't one of the plan's rows follows the last one (a folded region's header,
    /// a button): the last row keeps its region's boundary line instead of ending the list.
    public var isFollowedByContent = false

    public init() {}

    /// Adds a region. An empty one is ignored, so a folded region's rows can be passed as they are.
    public mutating func add(_ rows: [ID], boundary: SidebarRowDivider = .section) {
        guard !rows.isEmpty else { return }
        regions.append(Region(rows: rows, boundary: boundary))
    }

    /// Each row's line. Ids are expected once; a repeat keeps its last position's line.
    public var dividers: [ID: SidebarRowDivider] {
        var result: [ID: SidebarRowDivider] = [:]
        let total = regions.reduce(0) { $0 + $1.rows.count }
        guard total > 0 else { return result }
        var index = 0
        for region in regions {
            for position in region.rows.indices {
                let isRegionEnd = position == region.rows.count - 1
                let isListEnd = index == total - 1
                if isListEnd, !isFollowedByContent {
                    // Spelled out: in a dictionary's subscript `.none` would remove the row.
                    result[region.rows[position]] = SidebarRowDivider.none
                } else if isRegionEnd {
                    result[region.rows[position]] = region.boundary
                } else {
                    result[region.rows[position]] = .line
                }
                index += 1
            }
        }
        return result
    }
}
