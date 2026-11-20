import CoreGraphics
import XCTest
@testable import SizeCore

final class GridLayoutTests: XCTestCase {
    private let screen = CGRect(x: 10, y: 20, width: 1001, height: 701)

    func testHalvesTileWithoutGap() {
        let left = frame(for: GridRect(x: 0, y: 0, width: 3, height: 6), screen: screen)
        let right = frame(for: GridRect(x: 3, y: 0, width: 3, height: 6), screen: screen)
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertEqual(right.maxX, screen.maxX)
        XCTAssertEqual(left.maxX, right.minX, "halves must share an exact edge")
        XCTAssertEqual(left.union(right), screen)
    }

    func testQuadrantsTileScreen() {
        let rects = [
            GridRect(x: 0, y: 0, width: 3, height: 3),
            GridRect(x: 3, y: 0, width: 3, height: 3),
            GridRect(x: 0, y: 3, width: 3, height: 3),
            GridRect(x: 3, y: 3, width: 3, height: 3)
        ].map { frame(for: $0, screen: screen) }

        XCTAssertEqual(rects.reduce(CGRect.null) { $0.union($1) }, screen)
        XCTAssertEqual(rects[0].maxX, rects[1].minX)
        XCTAssertEqual(rects[0].minY, rects[2].maxY)
        XCTAssertEqual(rects[2].maxY, rects[3].maxY)
    }

    func testThirdsTileScreen() {
        let rects = [0, 2, 4].map {
            frame(for: GridRect(x: $0, y: 0, width: 2, height: 6), screen: screen)
        }
        XCTAssertEqual(rects.reduce(CGRect.null) { $0.union($1) }, screen)
        XCTAssertEqual(rects[0].maxX, rects[1].minX)
        XCTAssertEqual(rects[1].maxX, rects[2].minX)
    }

    func testVerticalThirdsTileScreen() {
        let rects = [0, 2, 4].map {
            frame(for: GridRect(x: 0, y: $0, width: 6, height: 2), screen: screen)
        }
        XCTAssertEqual(rects.reduce(CGRect.null) { $0.union($1) }, screen)
    }

    func testTwoThirdsAndOneThirdFillScreen() {
        let twoThirds = frame(for: GridRect(x: 0, y: 0, width: 4, height: 6), screen: screen)
        let rest = frame(for: GridRect(x: 4, y: 0, width: 2, height: 6), screen: screen)
        XCTAssertEqual(twoThirds.union(rest), screen)
        XCTAssertEqual(twoThirds.maxX, rest.minX)
    }

    func testTopLeftGridYIsFlippedToNSCoordinates() {
        let upper = frame(
            for: GridRect(x: 0, y: 0, width: 6, height: 3),
            screen: CGRect(x: 0, y: 0, width: 600, height: 600)
        )
        XCTAssertEqual(upper, CGRect(x: 0, y: 300, width: 600, height: 300))
    }

    func testGridRowZeroIsAlwaysTheTopHalf() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let top = frame(for: GridRect(x: 0, y: 0, width: 6, height: 3), screen: bounds)
        let bottom = frame(for: GridRect(x: 0, y: 3, width: 6, height: 3), screen: bounds)
        XCTAssertEqual(top.maxY, 100, "grid row 0 must be the top of the screen")
        XCTAssertEqual(bottom.minY, 0, "grid row 3 must be the bottom of the screen")
    }

    func testMarginIsApplied() {
        let result = frame(
            for: GridRect(x: 0, y: 0, width: 6, height: 6),
            screen: screen,
            margin: EdgeInsets(top: 5, left: 11, bottom: 13, right: 17)
        )
        XCTAssertEqual(result, CGRect(x: 21, y: 33, width: 973, height: 683))
    }

    func testMarginInsetsTheWholeLayout() {
        // margin is a screen-edge inset (SizeUp semantics); tiles still abut.
        let margin = EdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let left = frame(for: GridRect(x: 0, y: 0, width: 3, height: 6), screen: screen, margin: margin)
        let right = frame(for: GridRect(x: 3, y: 0, width: 3, height: 6), screen: screen, margin: margin)
        XCTAssertEqual(left.minX, screen.minX + 10)
        XCTAssertEqual(right.maxX, screen.maxX - 10)
        XCTAssertEqual(left.maxX, right.minX)
    }

    func testGapPutsSpaceBetweenNeighbouringWindows() {
        let left = frame(for: GridRect(x: 0, y: 0, width: 3, height: 6), screen: screen, gap: 16)
        let right = frame(for: GridRect(x: 3, y: 0, width: 3, height: 6), screen: screen, gap: 16)
        XCTAssertEqual(right.minX - left.maxX, 16, "adjacent windows must be separated by the gap")
        XCTAssertEqual(left.width, 501 - 16, accuracy: 1)
    }

    func testGapShrinksEveryEdge() {
        let full = frame(for: GridRect(x: 0, y: 0, width: 6, height: 6), screen: screen, gap: 20)
        XCTAssertEqual(full.minX, screen.minX + 10)
        XCTAssertEqual(full.maxX, screen.maxX - 10)
        XCTAssertEqual(full.width, screen.width - 20)
    }

    func testGapAndMarginCombine() {
        let result = frame(
            for: GridRect(x: 0, y: 0, width: 6, height: 6),
            screen: screen,
            margin: EdgeInsets(top: 4, left: 4, bottom: 4, right: 4),
            gap: 10
        )
        XCTAssertEqual(result.minX, screen.minX + 4 + 5)
        XCTAssertEqual(result.width, screen.width - 8 - 10)
    }

    func testHugeGapNeverProducesNegativeSize() {
        let result = frame(for: GridRect(x: 0, y: 0, width: 1, height: 1), screen: screen, gap: 10_000)
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
    }

    func testNegativeMarginIsClampedNotCrashing() {
        let result = frame(
            for: GridRect(x: 0, y: 0, width: 6, height: 6),
            screen: screen,
            margin: EdgeInsets(top: -5, left: -5, bottom: -5, right: -5)
        )
        XCTAssertEqual(result, screen)
    }

    func testOversizedGridRectIsClamped() {
        let result = frame(
            for: GridRect(x: -3, y: -3, width: 99, height: 99),
            screen: screen
        )
        XCTAssertEqual(result, screen)
    }

    func testEightByEightGridStillTiles() {
        let grid = GridSize(columns: 8, rows: 8)
        let left = frame(for: GridRect(x: 0, y: 0, width: 4, height: 8), in: grid, screen: screen)
        let right = frame(for: GridRect(x: 4, y: 0, width: 4, height: 8), in: grid, screen: screen)
        XCTAssertEqual(left.union(right), screen)
        XCTAssertEqual(left.maxX, right.minX)
    }

    func testEveryGridActionTilesItsRegionConsistently() {
        for action in WindowAction.gridActions {
            guard let rect = action.gridRect else {
                XCTFail("\(action) is a grid action without a rect")
                continue
            }
            let result = frame(for: rect, screen: screen)
            XCTAssertFalse(result.isEmpty, "\(action) produced an empty frame")
            XCTAssertTrue(
                screen.contains(result),
                "\(action) produced a frame outside the screen: \(result)"
            )
        }
    }
}

final class GridActionTests: XCTestCase {
    func testAllActionsAreClassified() {
        for action in WindowAction.allCases {
            switch action.category {
            case .grid:
                XCTAssertNotNil(action.gridRect, "\(action) is grid but has no rect")
                XCTAssertNil(action.nonGridReason)
            case .move, .center, .restore, .monitor, .space:
                XCTAssertNil(action.gridRect, "\(action) has a rect but is not a grid action")
                XCTAssertNotNil(action.nonGridReason, "\(action) should explain why it is not grid-based")
            }
        }
    }

    func testActionCountMatchesDocumentedVocabulary() {
        XCTAssertEqual(WindowAction.allCases.count, 34)
        XCTAssertEqual(Set(WindowAction.allCases).count, 34, "action names must be unique")
    }

    func testGridActionCountIsSeventeen() {
        XCTAssertEqual(WindowAction.gridActions.count, 17)
    }

    func testEveryGridRectFitsInStandardGrid() {
        let grid = GridSize.standard
        for action in WindowAction.gridActions {
            guard let rect = action.gridRect else { continue }
            XCTAssertGreaterThanOrEqual(rect.x, 0, "\(action)")
            XCTAssertGreaterThanOrEqual(rect.y, 0, "\(action)")
            XCTAssertLessThanOrEqual(rect.x + rect.width, grid.columns, "\(action) overflows horizontally")
            XCTAssertLessThanOrEqual(rect.y + rect.height, grid.rows, "\(action) overflows vertically")
        }
    }

    func testNoTwoGridActionsShareARect() {
        var seen: [GridRect: WindowAction] = [:]
        for action in WindowAction.gridActions {
            guard let rect = action.gridRect else { continue }
            if let existing = seen[rect] {
                XCTFail("\(action) duplicates \(existing)")
            }
            seen[rect] = action
        }
    }

    func testRawValuesRoundTripThroughInit() {
        for action in WindowAction.allCases {
            XCTAssertEqual(WindowAction(rawValue: action.rawValue), action)
            XCTAssertFalse(action.displayName.isEmpty, "\(action) needs a menu label")
        }
    }
}

final class ResolverTests: XCTestCase {
    private let singleScreen = [ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 950),
        index: 0
    )]

    private let dualScreen = [
        ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 950),
            index: 0
        ),
        ScreenInfo(
            frame: CGRect(x: 1600, y: 0, width: 1200, height: 900),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1200, height: 870),
            index: 1
        )
    ]

    private func resolve(
        _ action: WindowAction,
        window: CGRect = CGRect(x: 100, y: 100, width: 600, height: 400),
        screens: [ScreenInfo]? = nil,
        margin: EdgeInsets = .zero,
        savedFrame: CGRect? = nil
    ) -> ActionResolution {
        ActionResolver.resolve(action, input: ResolveInput(
            windowFrame: window,
            screens: screens ?? singleScreen,
            margin: margin,
            savedFrame: savedFrame
        ))
    }

    func testLeftHalfMatchesGrid() {
        guard case .frame(let result) = resolve(.left) else { return XCTFail() }
        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 800, height: 950))
    }

    func testFullScreenFillsVisibleFrame() {
        guard case .frame(let result) = resolve(.fullScreen) else { return XCTFail() }
        XCTAssertEqual(result, singleScreen[0].visibleFrame)
    }

    func testEveryGridActionProducesAFrameOnScreen() {
        for action in WindowAction.gridActions {
            guard case .frame(let result) = resolve(action) else {
                XCTFail("\(action) did not resolve to a frame")
                continue
            }
            XCTAssertTrue(
                singleScreen[0].visibleFrame.contains(result),
                "\(action) escaped the screen: \(result)"
            )
        }
    }

    func testMoveLeftKeepsSize() {
        let window = CGRect(x: 400, y: 300, width: 500, height: 300)
        guard case .frame(let result) = resolve(.moveLeft, window: window) else { return XCTFail() }
        XCTAssertEqual(result.size, window.size, "move actions must not resize")
        XCTAssertEqual(result.minX, 0)
        XCTAssertEqual(result.minY, window.minY, "untouched axis must not move")
    }

    func testMoveUpKeepsSizeAndHitsTop() {
        let window = CGRect(x: 400, y: 100, width: 500, height: 300)
        guard case .frame(let result) = resolve(.moveUp, window: window) else { return XCTFail() }
        XCTAssertEqual(result.size, window.size)
        XCTAssertEqual(result.maxY, singleScreen[0].visibleFrame.maxY)
        XCTAssertEqual(result.minX, window.minX)
    }

    func testMoveToEachCornerKeepsSize() {
        let window = CGRect(x: 500, y: 400, width: 400, height: 300)
        let bounds = singleScreen[0].visibleFrame
        let expectations: [(WindowAction, CGPoint)] = [
            (.moveUpperLeft, CGPoint(x: bounds.minX, y: bounds.maxY - 300)),
            (.moveUpperRight, CGPoint(x: bounds.maxX - 400, y: bounds.maxY - 300)),
            (.moveLowerLeft, CGPoint(x: bounds.minX, y: bounds.minY)),
            (.moveLowerRight, CGPoint(x: bounds.maxX - 400, y: bounds.minY))
        ]
        for (action, expected) in expectations {
            guard case .frame(let result) = resolve(action, window: window) else {
                XCTFail("\(action) did not resolve")
                continue
            }
            XCTAssertEqual(result.size, window.size, "\(action)")
            XCTAssertEqual(result.origin, expected, "\(action)")
        }
    }

    func testCenterPreservesSizeAndCentres() {
        let window = CGRect(x: 10, y: 20, width: 500, height: 300)
        guard case .frame(let result) = resolve(.center, window: window) else { return XCTFail() }
        XCTAssertEqual(result.size, window.size)
        let bounds = singleScreen[0].visibleFrame
        XCTAssertEqual(result.midX, bounds.midX, accuracy: 1)
        XCTAssertEqual(result.midY, bounds.midY, accuracy: 1)
    }

    func testCenterShrinksWindowLargerThanScreen() {
        let huge = CGRect(x: 0, y: 0, width: 5000, height: 5000)
        guard case .frame(let result) = resolve(.center, window: huge) else { return XCTFail() }
        XCTAssertLessThanOrEqual(result.width, singleScreen[0].visibleFrame.width)
        XCTAssertLessThanOrEqual(result.height, singleScreen[0].visibleFrame.height)
    }

    func testSnapBackWithoutSnapshotAsksForOne() {
        XCTAssertEqual(resolve(.snapBack), .needsSnapshot)
    }

    func testSnapBackReturnsSavedFrame() {
        let saved = CGRect(x: 42, y: 42, width: 333, height: 222)
        guard case .frame(let result) = resolve(.snapBack, savedFrame: saved) else { return XCTFail() }
        XCTAssertEqual(result, saved)
    }

    func testNextMonitorMovesToSecondDisplay() {
        guard case .frame(let result) = resolve(.nextMonitor, screens: dualScreen) else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(result.minX, 1600, "window must land on the second display")
    }

    func testPrevMonitorWrapsAround() {
        let window = CGRect(x: 1700, y: 100, width: 400, height: 300)
        guard case .frame(let result) = resolve(.prevMonitor, window: window, screens: dualScreen) else {
            return XCTFail()
        }
        XCTAssertLessThan(result.maxX, 1600, "window must land on the first display")
    }

    func testNextMonitorWrapsFromLastToFirst() {
        let window = CGRect(x: 1700, y: 100, width: 400, height: 300)
        guard case .frame(let result) = resolve(.nextMonitor, window: window, screens: dualScreen) else {
            return XCTFail()
        }
        XCTAssertLessThan(result.maxX, 1600)
    }

    func testMonitorActionWithSingleDisplayIsUnavailable() {
        guard case .unavailable = resolve(.nextMonitor) else {
            return XCTFail("single display should not offer monitor moves")
        }
    }

    /// Superseded: the old contract kept the window's pixel size, which left a
    /// band of desktop showing whenever the next display had another
    /// resolution. Relative geometry is preserved instead, so a window size is
    /// only equal on displays of equal size.
    func testMonitorTransferScalesWithDestination() {
        let window = CGRect(x: 200, y: 200, width: 500, height: 300)
        guard case .frame(let result) = resolve(.nextMonitor, window: window, screens: dualScreen) else {
            return XCTFail()
        }
        XCTAssertLessThan(result.width, window.width, "the destination display is narrower")
        XCTAssertTrue(result.minX >= 1600, "\(result) should sit on the second display")
    }

    func testSpaceActionsHandOffWithoutFrames() {
        for action in WindowAction.spaceActions {
            guard case .space = resolve(action) else {
                XCTFail("\(action) should hand off to the Space mover")
                continue
            }
        }
    }

    func testNoScreensIsUnavailable() {
        guard case .unavailable = resolve(.left, screens: []) else {
            return XCTFail()
        }
    }

    func testGridActionUsesScreenContainingWindow() {
        let onSecond = CGRect(x: 1700, y: 100, width: 300, height: 200)
        guard case .frame(let result) = resolve(.left, window: onSecond, screens: dualScreen) else {
            return XCTFail()
        }
        XCTAssertGreaterThanOrEqual(result.minX, 1600, "must tile against the display the window is on")
    }

    func testMarginAppliesToGridActions() {
        let margin = EdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        guard case .frame(let result) = resolve(.fullScreen, margin: margin) else { return XCTFail() }
        XCTAssertEqual(result.minX, 20)
        XCTAssertEqual(result.maxX, 1580)
    }

    func testGridActionWithGapKeepsWindowsApart() {
        let result = ActionResolver.resolve(.left, input: ResolveInput(
            windowFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            screens: singleScreen,
            gap: 12
        ))
        guard case .frame(let frame) = result else { return XCTFail() }
        XCTAssertEqual(frame.width, 800 - 12, accuracy: 1)
    }

    func testGridRectOverrideWins() {
        let result = ActionResolver.resolve(.left, input: ResolveInput(
            windowFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            screens: singleScreen,
            gridRectOverride: GridRect(x: 0, y: 0, width: 4, height: 6)
        ))
        guard case .frame(let frame) = result else { return XCTFail() }
        XCTAssertEqual(frame.width, 1067, accuracy: 1, "override should widen the left region")
    }
}

final class ScreenGeometryTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testCGNSRoundTrip() {
        let ns = CGRect(x: -800, y: 75, width: 501, height: 333)
        let cg = ScreenGeometry.cgRect(fromNS: ns, mainScreenFrame: main)
        XCTAssertEqual(ScreenGeometry.nsRect(fromCG: cg, mainScreenFrame: main), ns)
    }

    func testConversionMirrorsVertically() {
        let ns = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cg = ScreenGeometry.cgRect(fromNS: ns, mainScreenFrame: main)
        XCTAssertEqual(cg.minY, 882, "bottom of an NS screen maps to a large CG Y")
    }

    func testScreenIndexFindsDisplayByCentre() {
        let screens = [
            ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), index: 0),
            ScreenInfo(frame: CGRect(x: 1000, y: 0, width: 800, height: 600), visibleFrame: CGRect(x: 1000, y: 0, width: 800, height: 600), index: 1)
        ]
        XCTAssertEqual(
            ScreenGeometry.screenIndex(containing: CGRect(x: 1200, y: 100, width: 200, height: 200), screens: screens),
            1
        )
        XCTAssertEqual(
            ScreenGeometry.screenIndex(containing: CGRect(x: 100, y: 100, width: 200, height: 200), screens: screens),
            0
        )
    }

    func testScreenIndexFallsBackWhenWindowIsOffscreen() {
        let screens = [
            ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), index: 0)
        ]
        XCTAssertEqual(
            ScreenGeometry.screenIndex(containing: CGRect(x: 5000, y: 5000, width: 100, height: 100), screens: screens),
            0
        )
    }

    func testScreenIndexHandlesEmptyList() {
        XCTAssertNil(ScreenGeometry.screenIndex(containing: .zero, screens: []))
    }

    func testTransferredKeepsWindowInsideDestination() {
        let source = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), index: 0)
        let destination = ScreenInfo(frame: CGRect(x: 1000, y: 0, width: 600, height: 500), visibleFrame: CGRect(x: 1000, y: 0, width: 600, height: 470), index: 1)
        let window = CGRect(x: 700, y: 600, width: 300, height: 200)
        let moved = ScreenGeometry.transferred(window, from: source, to: destination)
        XCTAssertTrue(destination.visibleFrame.contains(moved), "\(moved) escaped \(destination.visibleFrame)")
    }

    // MARK: - Moving between displays of different resolution

    private var smallDisplay: ScreenInfo {
        ScreenInfo(
            frame: CGRect(x: 2304, y: 0, width: 1710, height: 1107),
            visibleFrame: CGRect(x: 2304, y: 0, width: 1710, height: 1077),
            index: 1
        )
    }

    private var largeDisplay: ScreenInfo {
        ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 2304, height: 1296),
            visibleFrame: CGRect(x: 0, y: 0, width: 2304, height: 1266),
            index: 0
        )
    }

    /// The reported bug: a maximised window sent to a display of a different
    /// resolution kept its old pixel size and left a band of desktop showing.
    func testMaximisedWindowFillsSmallerDestination() {
        let window = largeDisplay.visibleFrame
        let moved = ScreenGeometry.transferred(window, from: largeDisplay, to: smallDisplay)
        XCTAssertEqual(moved, smallDisplay.visibleFrame)
    }

    func testMaximisedWindowFillsLargerDestination() {
        let window = smallDisplay.visibleFrame
        let moved = ScreenGeometry.transferred(window, from: smallDisplay, to: largeDisplay)
        XCTAssertEqual(moved, largeDisplay.visibleFrame)
    }

    /// Menu bar heights differ per display, so a "full" window often misses the
    /// target edges by a few points. It should still be treated as full.
    func testNearlyMaximisedWindowStillSnapsToFullDestination() {
        let window = CGRect(x: 0, y: 0, width: 2304, height: 1260)
        let moved = ScreenGeometry.transferred(window, from: largeDisplay, to: smallDisplay)
        XCTAssertEqual(moved, smallDisplay.visibleFrame)
    }

    func testHalfScreenStaysHalfScreenAcrossDisplays() {
        let leftHalf = CGRect(x: 0, y: 0, width: 1152, height: 1266)
        let moved = ScreenGeometry.transferred(leftHalf, from: largeDisplay, to: smallDisplay)
        XCTAssertEqual(moved.minX, smallDisplay.visibleFrame.minX)
        XCTAssertEqual(moved.width, 855)
        XCTAssertEqual(moved.height, smallDisplay.visibleFrame.height)
    }

    func testQuarterWindowKeepsProportion() {
        let quarter = CGRect(x: 1152, y: 633, width: 1152, height: 633)
        let moved = ScreenGeometry.transferred(quarter, from: largeDisplay, to: smallDisplay)
        XCTAssertEqual(moved, CGRect(x: 2304 + 855, y: 539, width: 855, height: 538))
    }

    func testSmallWindowIsNotBlownUpToFullScreen() {
        let small = CGRect(x: 300, y: 300, width: 700, height: 528)
        let moved = ScreenGeometry.transferred(small, from: largeDisplay, to: smallDisplay)
        XCTAssertLessThan(moved.width, smallDisplay.visibleFrame.width * 0.9)
        XCTAssertTrue(smallDisplay.visibleFrame.contains(moved))
    }

    func testFullBleedRespectsMarginOnDestination() {
        let margin = EdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let window = CGRect(x: 10, y: 10, width: 2284, height: 1246)
        let moved = ScreenGeometry.transferred(
            window,
            from: largeDisplay,
            to: smallDisplay,
            margin: margin
        )
        XCTAssertEqual(moved.minX, smallDisplay.visibleFrame.minX + 10)
        XCTAssertEqual(moved.width, smallDisplay.visibleFrame.width - 20)
        XCTAssertEqual(moved.height, smallDisplay.visibleFrame.height - 20)
    }

    func testWindowHangingOffscreenLandsInsideDestination() {
        let offscreen = CGRect(x: -400, y: -100, width: 900, height: 700)
        let moved = ScreenGeometry.transferred(offscreen, from: largeDisplay, to: smallDisplay)
        XCTAssertTrue(smallDisplay.visibleFrame.contains(moved), "\(moved) escaped")
    }

    func testDegenerateWindowFallsBackToDestinationFrame() {
        let moved = ScreenGeometry.transferred(.zero, from: largeDisplay, to: smallDisplay)
        XCTAssertEqual(moved, smallDisplay.visibleFrame)
    }

    func testZeroSizedScreenDoesNotDivideByZero() {
        let empty = ScreenInfo(frame: .zero, visibleFrame: .zero, index: 2)
        let moved = ScreenGeometry.transferred(
            CGRect(x: 0, y: 0, width: 100, height: 100),
            from: empty,
            to: smallDisplay
        )
        XCTAssertTrue(smallDisplay.visibleFrame.contains(moved))
    }

    func testClampedOriginPullsWindowBackOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let origin = ScreenGeometry.clampedOrigin(
            for: CGSize(width: 400, height: 300),
            inside: bounds,
            preferred: CGPoint(x: -200, y: 2000)
        )
        XCTAssertEqual(origin, CGPoint(x: 0, y: 500))
    }
}

final class ConfigTests: XCTestCase {
    func testInheritUsesFallback() {
        let resolved = Margin.inherit.resolved(fallback: Margin(top: 10, bottom: 11, left: 12, right: 13))
        XCTAssertEqual(resolved, EdgeInsets(top: 10, left: 12, bottom: 11, right: 13))
    }

    func testExplicitValuesWinOverFallback() {
        let resolved = Margin(top: 5, bottom: 7, left: -1, right: -1)
            .resolved(fallback: Margin(top: 10, bottom: 11, left: 12, right: 13))
        XCTAssertEqual(resolved, EdgeInsets(top: 5, left: 12, bottom: 7, right: 13))
    }

    func testRoundTripThroughJSON() {
        var config = SizeConfig()
        config.gridColumns = 8
        config.gridRows = 4
        config.defaultMargin = Margin(top: 8, bottom: 8, left: 8, right: 8)
        config.ignoredBundleIDs = ["com.example.ignore"]
        config.overrides = ["com.example.app": AppOverride(
            disabled: true,
            margin: Margin(top: 4, bottom: -1, left: -1, right: -1)
        )]
        config.enableSpaceActions = true

        let decoded = SizeConfig.decode(from: config.encoded())
        XCTAssertEqual(decoded, config)
    }

    func testCorruptJSONFallsBackToDefaults() {
        let decoded = SizeConfig.decode(from: Data("not json".utf8))
        XCTAssertEqual(decoded, .default)
    }

    func testOutOfRangeGridIsSanitised() {
        let config = SizeConfig(gridColumns: 0, gridRows: 999).sanitised()
        XCTAssertEqual(config.gridColumns, 1)
        XCTAssertEqual(config.gridRows, 24)
    }

    func testIgnoredBundleIsReported() {
        let config = SizeConfig(ignoredBundleIDs: ["com.example.ignore"])
        XCTAssertTrue(config.isIgnored(bundleID: "com.example.ignore"))
        XCTAssertFalse(config.isIgnored(bundleID: "com.example.other"))
        XCTAssertFalse(config.isIgnored(bundleID: nil))
    }

    func testPerAppGridOverrideIsUsed() {
        var config = SizeConfig()
        config.overrides["com.example.ide"] = AppOverride(
            actionParams: ["left": GridRectCodable(x: 0, y: 0, width: 4, height: 6)]
        )
        XCTAssertEqual(
            config.gridRect(for: .left, bundleID: "com.example.ide"),
            GridRect(x: 0, y: 0, width: 4, height: 6)
        )
        XCTAssertEqual(
            config.gridRect(for: .left, bundleID: "com.example.other"),
            GridRect(x: 0, y: 0, width: 3, height: 6)
        )
    }

    func testMarginForAppFallsBackToDefault() {
        var config = SizeConfig(defaultMargin: Margin(top: 6, bottom: 6, left: 6, right: 6))
        config.overrides["com.example.app"] = AppOverride(margin: Margin(top: 0, bottom: -1, left: -1, right: -1))
        XCTAssertEqual(config.margin(for: "com.example.app"), EdgeInsets(top: 0, left: 6, bottom: 6, right: 6))
        XCTAssertEqual(config.margin(for: "com.example.other"), EdgeInsets(top: 6, left: 6, bottom: 6, right: 6))
        XCTAssertEqual(config.margin(for: nil), EdgeInsets(top: 6, left: 6, bottom: 6, right: 6))
    }
}

final class HotkeyConfigTests: XCTestCase {
    func testDefaultBindingAppliesWhenNothingIsCustomised() {
        let config = SizeConfig()
        XCTAssertEqual(config.binding(for: .left), DefaultHotkeys.binding(for: .left))
        XCTAssertFalse(config.isCustomised(.left))
    }

    func testSpaceActionsHaveNoShortcut() {
        let config = SizeConfig()
        for action in WindowAction.spaceActions {
            XCTAssertNil(config.binding(for: action), "\(action) should not be bindable")
            XCTAssertFalse(action.isHotkeyable)
        }
    }

    func testCustomBindingOverridesDefault() {
        var config = SizeConfig()
        let custom = HotkeyBinding(keyCode: 0, modifiers: HotkeyModifiers.control | HotkeyModifiers.shift)
        config.setBinding(custom, for: .left)
        XCTAssertEqual(config.binding(for: .left), custom)
        XCTAssertTrue(config.isCustomised(.left))
    }

    func testClearingABindingDisablesIt() {
        var config = SizeConfig()
        config.setBinding(nil, for: .right)
        XCTAssertNil(config.binding(for: .right), "a deliberately cleared shortcut stays cleared")
        XCTAssertTrue(config.isCustomised(.right))
    }

    func testResetRestoresTheDefault() {
        var config = SizeConfig()
        config.setBinding(HotkeyBinding(keyCode: 0, modifiers: HotkeyModifiers.command), for: .left)
        config.resetBinding(for: .left)
        XCTAssertEqual(config.binding(for: .left), DefaultHotkeys.binding(for: .left))
        XCTAssertFalse(config.isCustomised(.left))
    }

    func testBindingSurvivesJSONRoundTrip() {
        var config = SizeConfig()
        let custom = HotkeyBinding(keyCode: 17, modifiers: HotkeyModifiers.control | HotkeyModifiers.option)
        config.setBinding(custom, for: .fullScreen)
        config.setBinding(nil, for: .down)

        let decoded = SizeConfig.decode(from: config.encoded())
        XCTAssertEqual(decoded.binding(for: .fullScreen), custom)
        XCTAssertNil(decoded.binding(for: .down))
        XCTAssertTrue(decoded.isCustomised(.down))
    }

    func testBindingDisplayIsReadable() {
        let binding = HotkeyBinding(
            keyCode: 123,
            modifiers: HotkeyModifiers.control | HotkeyModifiers.option
        )
        XCTAssertEqual(binding.display, "⌃⌥←")
        XCTAssertTrue(binding.isValid)
    }

    func testBindingWithoutModifierIsInvalid() {
        XCTAssertFalse(HotkeyBinding(keyCode: 0, modifiers: 0).isValid)
        XCTAssertTrue(HotkeyBinding(keyCode: 0, modifiers: HotkeyModifiers.command).isValid)
    }
}

final class SnapshotStoreTests: XCTestCase {
    private let frameA = CGRect(x: 1, y: 2, width: 3, height: 4)
    private let frameB = CGRect(x: 9, y: 9, width: 9, height: 9)

    func testRecallReturnsRememberedFrame() {
        var store = SnapshotStore()
        store.remember(key: "w1", frame: frameA)
        XCTAssertEqual(store.recall(key: "w1"), frameA)
        XCTAssertNil(store.recall(key: "missing"))
    }

    func testFirstSnapshotWinsSoUndoReturnsToOriginal() {
        var store = SnapshotStore()
        store.remember(key: "w1", frame: frameA)
        store.remember(key: "w1", frame: frameB)
        XCTAssertEqual(store.recall(key: "w1"), frameA)
    }

    func testOverwriteReplacesSnapshot() {
        var store = SnapshotStore()
        store.remember(key: "w1", frame: frameA)
        store.remember(key: "w1", frame: frameB, overwrite: true)
        XCTAssertEqual(store.recall(key: "w1"), frameB)
    }

    func testRetainDropsClosedWindows() {
        var store = SnapshotStore()
        store.remember(key: "w1", frame: frameA)
        store.remember(key: "w2", frame: frameB)
        store.retain(keys: ["w2"])
        XCTAssertNil(store.recall(key: "w1"))
        XCTAssertEqual(store.recall(key: "w2"), frameB)
    }

    func testForgetRemovesEntry() {
        var store = SnapshotStore()
        store.remember(key: "w1", frame: frameA)
        store.forget(key: "w1")
        XCTAssertNil(store.recall(key: "w1"))
    }
}
