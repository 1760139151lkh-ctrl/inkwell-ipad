#if DEBUG
import Foundation
import SwiftData
import PencilKit

/// Debug-only: a realistic call for testing "Hand off to agent" end to end.
///   INKWELL_EMPTY=1 INKWELL_HANDOFF_TEST_DIR=<review/handoff-test>
/// Three speakers, two recordings, action items with owners and dates, an open question,
/// a decision — and handwritten notes timed to when each point was said.
enum HandoffTestSeed {
    static func seedIfRequested(context: ModelContext) {
        guard let dir = ProcessInfo.processInfo.environment["INKWELL_HANDOFF_TEST_DIR"] else { return }
        do { try seed(context: context, assets: URL(fileURLWithPath: dir)) } catch { print("HandoffTestSeed failed: \(error)") }
    }

    static func seed(context: ModelContext, assets: URL) throws {
        let font = try StrokeFont(url: assets.appendingPathComponent("EMSFelix.json"))
        let subject = Subject(name: "Client Work", colorHex: "#4FB3A9", sortIndex: 0)
        context.insert(subject)
        let start = Date().addingTimeInterval(-40 * 60)
        let note = DemoSeeder.makeNote(context: context, title: "Onboarding revamp - kickoff", subject: subject,
                                       paper: Paper(style: .ruled), created: start.addingTimeInterval(-60))
        let script = try JSONDecoder().decode(DemoSeeder.DemoScript.self, from: Data(contentsOf: assets.appendingPathComponent("script.json")))
        var recordings: [Recording] = []
        for (i, rs) in script.recordings.enumerated() {
            recordings.append(try DemoSeeder.makeRecording(context: context, note: note, order: i, name: rs.name,
                                                           startedAt: start.addingTimeInterval(Double(i) * 180),
                                                           script: rs, assets: assets))
        }
        typealias L = DemoSeeder.Line
        let blue = "#2F6FE4", red = "#E0343C"
        let lines: [L] = [
            L(text: "Onboarding revamp - kickoff", y: 86, size: 32),
            L(text: "activation 41% -> 34% (Sept)", y: 150, at: (0, 12.5)),
            L(text: "stall @ connect calendar", y: 196, at: (0, 16.0)),
            L(text: "Google sign-in times out, mobile Safari ~1/5", y: 242, size: 21, at: (0, 21.0)),
            L(text: "Marcus: fix sign-in + retry -> Thu", y: 300, color: blue, at: (0, 35.0)),
            L(text: "Priya: copy + Figma flow -> Wed", y: 346, color: blue, at: (0, 42.5)),
            L(text: "me: email Northwind / Globex / Initech", y: 392, color: blue, at: (0, 50.0)),
            L(text: "? keep product tour", y: 460, color: red, at: (1, 3.0)),
            L(text: "CUT tour, keep consent screen", y: 516, at: (1, 17.0)),
            L(text: "next sync Fri 10am", y: 576, at: (1, 21.0)),
        ]
        let marks: [DemoSeeder.Mark] = [
            DemoSeeder.Mark(kind: .box, rect: CGRect(x: 44, y: 490, width: 380, height: 40), color: red, at: (1, 19.5)),
            DemoSeeder.Mark(kind: .underline, rect: CGRect(x: 54, y: 92, width: 350, height: 0), color: "#1A1A1A", at: nil),
        ]
        DemoSeeder.writeDrawing(note: note, lines: lines, marks: marks, font: font, recordings: recordings,
                                untimedBase: start.addingTimeInterval(-50))
        try context.save()
    }
}
#endif
