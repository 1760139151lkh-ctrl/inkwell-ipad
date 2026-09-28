import XCTest
import PencilKit
@testable import Inkwell

/// Phase 3 handoff: ink → timed "moments", and the backup freshness check it relies on.
@MainActor final class HandoffTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    let geo = PageGeometry(paper: Paper())

    private func line(y: CGFloat, x0: CGFloat = 60, x1: CGFloat = 200, at date: Date) -> PKStroke {
        let pts = stride(from: x0, through: x1, by: 4).map {
            PKStrokePoint(location: CGPoint(x: $0, y: y), timeOffset: 0, size: CGSize(width: 2, height: 2),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: date))
    }

    private var timeline: NoteTimeline { NoteTimeline([(id: UUID(), startedAt: t0, duration: 120)]) }

    func testStrokesOnOneLineInQuickSuccessionAreOneMoment() {
        let strokes = [line(y: 100, at: t0.addingTimeInterval(10)),
                       line(y: 102, x0: 210, x1: 300, at: t0.addingTimeInterval(11))]
        let c = HandoffBuilder.cluster(strokes, geometry: geo, timeline: timeline)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].tStart!, 10, accuracy: 0.01)
        XCTAssertEqual(c[0].tEnd!, 11, accuracy: 0.01)
    }

    func testPauseOrNewLineStartsNewMoment() {
        let strokes = [line(y: 100, at: t0.addingTimeInterval(10)),
                       line(y: 100, x0: 210, x1: 300, at: t0.addingTimeInterval(20)),   // long pause
                       line(y: 200, at: t0.addingTimeInterval(20.5))]                  // jumped lines
        XCTAssertEqual(HandoffBuilder.cluster(strokes, geometry: geo, timeline: timeline).count, 3)
    }

    func testSecondPageAndNoRecording() {
        let y2 = geo.pageRect(1).minY + 100
        let strokes = [line(y: y2, at: t0.addingTimeInterval(-500))]   // written before any recording
        let c = HandoffBuilder.cluster(strokes, geometry: geo, timeline: timeline)
        XCTAssertEqual(c.first?.page, 1)
        XCTAssertNil(c.first?.tStart)
    }

    func testSpecksAreDropped() {
        let dot = line(y: 100, x0: 60, x1: 64, at: t0.addingTimeInterval(5))
        XCTAssertTrue(HandoffBuilder.cluster([dot], geometry: geo, timeline: timeline).isEmpty)
    }

    func testBackupFreshnessIsExactNotOrdered() {
        // An edit stamped *earlier* than the last backup (clock moved back) must still count as an edit.
        XCTAssertTrue(BackupEngine.sameInstant(t0, t0.addingTimeInterval(0.0001)))
        XCTAssertFalse(BackupEngine.sameInstant(t0, t0.addingTimeInterval(-60)))
    }
}
