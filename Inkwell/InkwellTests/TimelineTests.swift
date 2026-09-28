import XCTest
import PencilKit
@testable import Inkwell

/// PRD §12: unit-test the timeline math (timelineTime, offsets, hit-testing).
@MainActor final class TimelineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func twoRecordings() -> NoteTimeline {
        // Recording 1: 60 s. Recording 2 starts 10 min later, 30 s long.
        NoteTimeline([
            (id: UUID(), startedAt: t0, duration: 60),
            (id: UUID(), startedAt: t0.addingTimeInterval(600), duration: 30),
        ])
    }

    func testTotalIsSumAndBoundaryTick() {
        let tl = twoRecordings()
        XCTAssertEqual(tl.totalDuration, 90, accuracy: 0.0001)
        XCTAssertEqual(tl.boundaries, [60])
    }

    func testStrokeInFirstRecording() {
        let tl = twoRecordings()
        XCTAssertEqual(tl.timelineTime(of: t0.addingTimeInterval(20))!, 20, accuracy: 0.0001)
    }

    func testStrokeInSecondRecordingMapsAfterFirst() {
        // §7.5 #4: words from recording 2 map correctly.
        let tl = twoRecordings()
        XCTAssertEqual(tl.timelineTime(of: t0.addingTimeInterval(600 + 12))!, 72, accuracy: 0.0001)
    }

    func testStrokeOutsideRecordingsIsUntimed() {
        // §7.5 #5: ink before the first recording is never faded.
        let tl = twoRecordings()
        XCTAssertNil(tl.timelineTime(of: t0.addingTimeInterval(-5)))
        XCTAssertNil(tl.timelineTime(of: t0.addingTimeInterval(300)))
    }

    func testZeroDurationRecordingsAreSkipped() {
        let tl = NoteTimeline([(id: UUID(), startedAt: t0, duration: 0), (id: UUID(), startedAt: t0.addingTimeInterval(100), duration: 10)])
        XCTAssertEqual(tl.segments.count, 1)
        XCTAssertEqual(tl.segments[0].offset, 0)
    }

    func testLocate() {
        let tl = twoRecordings()
        XCTAssertEqual(tl.locate(10)?.index, 0)
        XCTAssertEqual(tl.locate(75)?.index, 1)
        XCTAssertEqual(tl.locate(75)!.local, 15, accuracy: 0.0001)
        XCTAssertEqual(tl.locate(500)?.index, 1)
    }

    func testRevealedCountAndFuture() {
        // §7.5 #1/#3: words at 5 s, 20 s, 40 s; scrub to 25 s → first two dark, third faded.
        let tl = NoteTimeline([(id: UUID(), startedAt: t0, duration: 60)])
        let dates = [t0.addingTimeInterval(-30), t0.addingTimeInterval(5), t0.addingTimeInterval(20), t0.addingTimeInterval(40)]
        let index = StrokeTimeIndex(creationDates: dates, timeline: tl)
        XCTAssertEqual(index.revealedCount(at: 25), 2)
        XCTAssertFalse(index.isFuture(0, at: 0), "untimed ink is never faded")
        XCTAssertFalse(index.isFuture(1, at: 25))
        XCTAssertFalse(index.isFuture(2, at: 25))
        XCTAssertTrue(index.isFuture(3, at: 25))
        XCTAssertEqual(index.revealedCount(at: 0), 0)
        XCTAssertEqual(index.revealedCount(at: 60), 3)
    }

    func testHitTestPicksLatestStroke() {
        func line(_ y: CGFloat, _ date: Date) -> PKStroke {
            let pts = stride(from: 0.0, through: 100.0, by: 10.0).map {
                PKStrokePoint(location: CGPoint(x: $0, y: y), timeOffset: 0, size: CGSize(width: 2, height: 2),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: date))
        }
        let a = line(100, t0)
        let b = line(104, t0.addingTimeInterval(30))   // overlaps a, written later
        let c = line(300, t0.addingTimeInterval(60))
        XCTAssertEqual(StrokeHitTester.hit(point: CGPoint(x: 50, y: 102), strokes: [a, b, c]), 1)
        XCTAssertEqual(StrokeHitTester.hit(point: CGPoint(x: 50, y: 300), strokes: [a, b, c]), 2)
        XCTAssertNil(StrokeHitTester.hit(point: CGPoint(x: 50, y: 200), strokes: [a, b, c]))
    }

    func testPageGeometry() {
        let g = PageGeometry(paper: Paper())
        XCTAssertEqual(g.pageIndex(forY: 0), 0)
        XCTAssertEqual(g.pageIndex(forY: 791), 0)
        XCTAssertEqual(g.pageIndex(forY: 792 + 16 + 1), 1)
        XCTAssertEqual(g.contentHeight(pageCount: 2), 792 * 2 + 16)
    }

    /// M3-5 (PRD §7.2): creationDate must survive a lasso move (a transform on the stroke)
    /// and a round trip through PKDrawing data (copy/paste and save/load both serialize).
    func testCreationDateSurvivesTransformAndSerialization() throws {
        let date = t0.addingTimeInterval(42)
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 5), CGPoint(x: 40, y: 0)].map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        var stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: date))
        stroke.transform = CGAffineTransform(translationX: 120, y: 80)
        let data = PKDrawing(strokes: [stroke]).dataRepresentation()
        let restored = try PKDrawing(data: data)
        XCTAssertEqual(restored.strokes.first!.path.creationDate.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }
}
