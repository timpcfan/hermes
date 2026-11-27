import Testing
@testable import HermesKit

@Suite("Row dividers")
struct RowDividerPlanTests {
    @Test func aListWithNoRowsHasNoLines() {
        let plan = RowDividerPlan<String>()
        #expect(plan.dividers.isEmpty)
    }

    @Test func rowsOfOneRegionGetALineBetweenThemAndNoneAfterTheLast() {
        var plan = RowDividerPlan<String>()
        plan.add(["a", "b", "c"])
        #expect(plan.dividers == ["a": .line, "b": .line, "c": .none])
    }

    @Test func aRegionsBoundaryFallsUnderItsLastRowWhileAnotherRegionFollows() {
        var plan = RowDividerPlan<String>()
        plan.add(["a", "b"], boundary: .section)
        plan.add(["c", "d"])
        #expect(plan.dividers == ["a": .line, "b": .section, "c": .line, "d": .none])
    }

    @Test func aGentleBoundaryKeepsTwoRunsVisuallyTogether() {
        // Pinned and Main are separate regions with no header between them; the iPhone breaks the
        // line at Pinned's end but the sidebar keeps it quiet.
        var plan = RowDividerPlan<String>()
        plan.add(["a"], boundary: .line)
        plan.add(["b"])
        #expect(plan.dividers == ["a": .line, "b": .none])
    }

    @Test func contentAfterTheLastRowKeepsThatRowsBoundary() {
        var plan = RowDividerPlan<String>()
        plan.add(["a", "b"], boundary: .section)
        plan.isFollowedByContent = true
        #expect(plan.dividers == ["a": .line, "b": .section])
    }

    @Test func aSingleRowBeforeAHeaderGetsTheStrongerLine() {
        var plan = RowDividerPlan<String>()
        plan.add(["only"], boundary: .section)
        plan.isFollowedByContent = true
        #expect(plan.dividers == ["only": .section])
    }

    @Test func anEmptyRegionIsIgnored() {
        var plan = RowDividerPlan<String>()
        plan.add([])
        plan.add(["a"], boundary: .none)
        #expect(plan.dividers == ["a": .none])
    }

    @Test func aFoldedRegionAddsNoRowsAndTheRegionBeforeItEndsTheList() {
        var plan = RowDividerPlan<String>()
        plan.add(["a", "b"], boundary: .section)
        plan.add([], boundary: .section)
        #expect(plan.dividers == ["a": .line, "b": .none])
    }

    @Test func boundariesAreKeptWhenEveryRegionHasOneRow() {
        var plan = RowDividerPlan<String>()
        plan.add(["a"])
        plan.add(["b"])
        plan.add(["c"], boundary: .none)
        #expect(plan.dividers == ["a": .section, "b": .section, "c": .none])
    }

    @Test func intIdentifiersWorkTheSame() {
        var plan = RowDividerPlan<Int>()
        plan.add([1, 2], boundary: .line)
        plan.add([3])
        #expect(plan.dividers == [1: .line, 2: .line, 3: .none])
    }
}
