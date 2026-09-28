import Foundation
import CoreGraphics
import PencilKit

/// A note's recordings laid end to end as one continuous timeline (PRD §7.2).
nonisolated struct NoteTimeline: Equatable {
    struct Segment: Equatable {
        var recordingID: UUID
        var startedAt: Date
        var duration: TimeInterval
        /// Σ duration of the recordings before this one.
        var offset: TimeInterval

        var endedAt: Date { startedAt.addingTimeInterval(duration) }
    }

    var segments: [Segment]

    init(segments: [Segment]) { self.segments = segments }

    /// Build from (id, startedAt, duration) in timeline order.
    init(_ items: [(id: UUID, startedAt: Date, duration: TimeInterval)]) {
        var offset: TimeInterval = 0
        var segs: [Segment] = []
        for item in items where item.duration > 0 {
            segs.append(Segment(recordingID: item.id, startedAt: item.startedAt, duration: item.duration, offset: offset))
            offset += item.duration
        }
        segments = segs
    }

    var totalDuration: TimeInterval { segments.last.map { $0.offset + $0.duration } ?? 0 }

    /// Offsets where one recording ends and the next begins (for scrubber ticks).
    var boundaries: [TimeInterval] { segments.dropFirst().map(\.offset) }

    /// Wall-clock → note-timeline time. `nil` = written outside any recording ("untimed").
    func timelineTime(of date: Date) -> TimeInterval? {
        guard let seg = segments.first(where: { date >= $0.startedAt && date <= $0.endedAt }) else { return nil }
        return seg.offset + date.timeIntervalSince(seg.startedAt)
    }

    /// Which recording is playing at timeline time `t`, and the recording-relative time.
    func locate(_ t: TimeInterval) -> (index: Int, local: TimeInterval)? {
        guard !segments.isEmpty else { return nil }
        for (i, seg) in segments.enumerated() where t < seg.offset + seg.duration {
            return (i, max(0, t - seg.offset))
        }
        let last = segments.count - 1
        return (last, segments[last].duration)
    }

    func offset(of recordingID: UUID) -> TimeInterval? {
        segments.first { $0.recordingID == recordingID }?.offset
    }
}

/// Sorted index of timed strokes, rebuilt on every drawing change (PRD §7.2).
nonisolated struct StrokeTimeIndex {
    /// (timeline time, stroke index) sorted by time.
    private(set) var entries: [(time: TimeInterval, stroke: Int)] = []
    /// Per-stroke timeline time, `nil` = untimed. Same order as `drawing.strokes`.
    private(set) var times: [TimeInterval?] = []

    init() {}

    init(creationDates: [Date], timeline: NoteTimeline) {
        times = creationDates.map { timeline.timelineTime(of: $0) }
        entries = times.enumerated().compactMap { i, t in t.map { ($0, i) } }.sorted { $0.time < $1.time }
    }

    init(drawing: PKDrawing, timeline: NoteTimeline) {
        self.init(creationDates: drawing.strokes.map { $0.path.creationDate }, timeline: timeline)
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Number of timed strokes with time ≤ t (binary search). Used to detect when the
    /// playhead crosses a stroke boundary, so the replay drawing is only rebuilt then.
    func revealedCount(at t: TimeInterval) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func isFuture(_ strokeIndex: Int, at t: TimeInterval) -> Bool {
        guard strokeIndex < times.count, let st = times[strokeIndex] else { return false }
        return st > t
    }

    /// The timeline time of the most recent timed stroke at or before `t` (for auto-scroll).
    func latestStroke(atOrBefore t: TimeInterval) -> Int? {
        let n = revealedCount(at: t)
        return n > 0 ? entries[n - 1].stroke : nil
    }
}

/// Tap-to-seek hit testing (PRD §7.4).
nonisolated enum StrokeHitTester {
    /// Returns the index of the hit stroke with the latest creationDate, or nil.
    static func hit(point: CGPoint, strokes: [PKStroke], tolerance: CGFloat = 12) -> Int? {
        var best: (index: Int, date: Date)?
        for (i, stroke) in strokes.enumerated() {
            let bounds = stroke.renderBounds.insetBy(dx: -8, dy: -8)
            guard bounds.contains(point) else { continue }
            if minDistance(from: point, to: stroke) < tolerance {
                let date = stroke.path.creationDate
                if best == nil || date > best!.date { best = (i, date) }
            }
        }
        return best?.index
    }

    static func minDistance(from p: CGPoint, to stroke: PKStroke) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        var previous: CGPoint?
        for point in stroke.path.interpolatedPoints(by: .distance(4)) {
            let loc = point.location.applying(stroke.transform)
            if let prev = previous {
                best = min(best, distance(p, segmentFrom: prev, to: loc))
            } else {
                best = min(best, hypot(p.x - loc.x, p.y - loc.y))
            }
            previous = loc
        }
        return best
    }

    static func distance(_ p: CGPoint, segmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
