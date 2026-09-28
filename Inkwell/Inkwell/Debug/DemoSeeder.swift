#if DEBUG
import Foundation
import SwiftData
import PencilKit
import AVFoundation
import UIKit

/// Debug-only: fills the library with realistic demo notes for the screens review
/// (PRD §12 M3.5). Driven by launch environment:
///
///   INKWELL_DEMO_DIR=<path to review/demo-assets>   seed from these assets (wipes the store first)
///   INKWELL_EMPTY=1                                  wipe the store, seed nothing
///   INKWELL_SCREEN=<name>                            open the app in a given state (see applyLaunchState)
///
/// Handwriting uses the single-stroke EMS Felix font (SIL OFL) so demo ink looks written, and
/// each stroke's creationDate is set to when that line was "spoken" in the demo audio, so
/// replay + tap-to-seek work on the seeded note exactly as on a real one.
enum DemoSeeder {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Call before the ModelContainer opens: deletes the store + note files when a demo
    /// launch asks for a clean slate. (Batch deletes through the context don't reliably clear
    /// related models, which left duplicates behind.)
    static func resetStoreIfRequested() {
        guard env["INKWELL_EMPTY"] == "1" || env["INKWELL_DEMO_DIR"] != nil else { return }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            try? fm.removeItem(at: support.appendingPathComponent(name))
        }
        try? fm.removeItem(at: NoteFiles.root)
        try? fm.createDirectory(at: NoteFiles.root, withIntermediateDirectories: true)
        try? fm.removeItem(at: BackupManifest.url)
        UserDefaults.standard.removeObject(forKey: "tool.current")
        UserDefaults.standard.removeObject(forKey: "lastOpenNote")
        UserDefaults.standard.removeObject(forKey: "backup.lastAt")
    }

    static func seedIfRequested(context: ModelContext) {
        guard env["INKWELL_EMPTY"] != "1", let dir = env["INKWELL_DEMO_DIR"] else { return }
        do {
            try seed(context: context, assets: URL(fileURLWithPath: dir))
        } catch {
            print("DemoSeeder failed: \(error)")
        }
    }

    // MARK: - Content

    struct Line {
        var text: String
        var x: CGFloat = 54
        var y: CGFloat
        var size: CGFloat = 25
        var color = "#1A1A1A"
        /// (recording index, seconds into that recording); nil = written before recording.
        var at: (Int, Double)?
    }

    struct Mark {
        enum Kind { case highlight, box, underline }
        var kind: Kind
        var rect: CGRect
        var color: String
        var at: (Int, Double)?
    }

    static func seed(context: ModelContext, assets: URL) throws {
        let font = try StrokeFont(url: assets.appendingPathComponent("EMSFelix.json"))
        let cal = Calendar.current
        let now = Date()

        func subject(_ name: String, _ hex: String, _ i: Int) -> Subject {
            let s = Subject(name: name, colorHex: hex, sortIndex: i)
            context.insert(s)
            return s
        }
        if env["INKWELL_DEMO_MINIMAL"] == "1" {
            // Backup round-trip test: one clearly named note with ink, two recordings, transcripts.
            let s = subject("ZZ Backup Test", "#8E6BD8", 0)
            let start = cal.date(byAdding: .hour, value: -1, to: now)!
            let n = makeNote(context: context, title: "ZZ backup test note", subject: s, paper: Paper(style: .ruled), created: start)
            let script = try JSONDecoder().decode(DemoScript.self, from: Data(contentsOf: assets.appendingPathComponent("script.json")))
            var recs: [Recording] = []
            for (i, rs) in script.recordings.enumerated() {
                recs.append(try makeRecording(context: context, note: n, order: i, name: rs.name,
                                              startedAt: start.addingTimeInterval(Double(i) * 600), script: rs, assets: assets))
            }
            writeDrawing(note: n, lines: [Line(text: "backup test", y: 90, size: 32), Line(text: "- timed line", y: 150, at: (0, 6))],
                         marks: [], font: font, recordings: recs, untimedBase: start.addingTimeInterval(-60))
            try context.save()
            return
        }
        let advisory = subject("AI Advisory", "#8BC77A", 0)
        let consulting = subject("Consulting", "#2F7D46", 1)
        let workshops = subject("AI Workshops", "#4FB3A9", 2)
        let internalSubject = subject("Internal", "#B8324B", 3)
        let discovery = subject("Client Discovery", "#E0603A", 4)
        // A divider grouping the client-facing subjects (P1 dividers).
        let clients = SubjectDivider(name: "Clients", sortIndex: 0)
        context.insert(clients)
        consulting.divider = clients
        discovery.divider = clients

        // Main note: two recordings with transcripts, ink timed to the call.
        let mainStart = cal.date(byAdding: .hour, value: -3, to: now)!
        let main = makeNote(context: context, title: "Launch sync", subject: advisory,
                            paper: Paper(style: .blank), created: mainStart.addingTimeInterval(-120))
        let script = try JSONDecoder().decode(DemoScript.self, from: Data(contentsOf: assets.appendingPathComponent("script.json")))
        let recStarts = [mainStart, mainStart.addingTimeInterval(22 * 60)]
        var recordings: [Recording] = []
        for (i, rs) in script.recordings.enumerated() {
            let rec = try makeRecording(context: context, note: main, order: i, name: rs.name, startedAt: recStarts[i],
                                        script: rs, assets: assets)
            recordings.append(rec)
        }
        let mainLines: [Line] = [
            Line(text: "Launch sync", y: 78, size: 36),
            Line(text: "Sep 24  ·  Dana, Marco, me", y: 116, size: 19, color: "#6B6B6B"),
            Line(text: "- launch moves to Friday", y: 176, at: (0, 8.4)),
            Line(text: "(+2 days QA on checkout)", x: 84, y: 214, size: 21, color: "#6B6B6B", at: (0, 13.6)),
            Line(text: "- Marco owns pricing page", y: 262, at: (0, 19.8)),
            Line(text: "new tiers + annual discount", x: 84, y: 300, size: 21, color: "#6B6B6B", at: (0, 23.8)),
            Line(text: "! Stripe webhooks for refunds", y: 350, color: "#E0343C", at: (0, 26.6)),
            Line(text: "-> top eng priority this week", x: 84, y: 388, size: 21, color: "#6B6B6B", at: (0, 32.8)),
            Line(text: "- onboarding emails: final pass", y: 436, at: (0, 38.6)),
            Line(text: "Q: who signs off on copy?", y: 514, color: "#2F6FE4", at: (1, 1.2)),
            Line(text: "me = final  ·  legal = refund text", x: 84, y: 552, size: 21, color: "#6B6B6B", at: (1, 5.6)),
            Line(text: "TODO  recap + Loom by Mon", y: 612, at: (1, 10.4)),
        ]
        let mainMarks: [Mark] = [
            Mark(kind: .highlight, rect: CGRect(x: 50, y: 160, width: 320, height: 26), color: "#FFE14D", at: (0, 13.0)),
            Mark(kind: .box, rect: CGRect(x: 44, y: 586, width: 330, height: 40), color: "#E0343C", at: (1, 14.2)),
            Mark(kind: .underline, rect: CGRect(x: 54, y: 84, width: 262, height: 0), color: "#1A1A1A", at: nil),
        ]
        // Demo note is TYPED serif text, not handwriting (Pat's call 2026-09-25). Marks stay as ink.
        for line in mainLines {
            let el = PageElement(kind: .text, frame: CGRect(x: line.x - 6, y: line.y - line.size, width: 470, height: line.size + 8))
            el.text = line.text
            el.fontSize = Double(line.size) * 0.80
            el.colorHex = line.color
            el.isBold = line.size >= 30
            el.frame.size.height = ElementSnapshot.textHeight(
                line.text, width: 470, font: ElementSnapshot.serif(CGFloat(line.size) * 0.80, bold: line.size >= 30))
            // Give every line the time it was "written" so the replay fade treats typed text
            // exactly like ink: anything after the playhead renders faded.
            if let (r, t) = line.at, r < recordings.count {
                el.createdAt = recordings[r].startedAt.addingTimeInterval(t)
            } else {
                el.createdAt = mainStart.addingTimeInterval(-90)
            }
            context.insert(el)
            main.elements.append(el)
        }
        writeDrawing(note: main, lines: [], marks: mainMarks, font: font, recordings: recordings,
                     untimedBase: mainStart.addingTimeInterval(-90))

        // Library population.
        struct Simple { var title: String; var subject: Subject; var daysAgo: Int; var paper: Paper; var lines: [Line]; var audio: Bool = false }
        let simple: [Simple] = [
            Simple(title: "Agent handoff ideas", subject: advisory, daysAgo: 6, paper: Paper(style: .ruled), lines: [
                Line(text: "Hand off to agent", y: 92, size: 32),
                Line(text: "- ink + transcript + timing", y: 150),
                Line(text: "- pick repo from subject?", y: 208),
                Line(text: "- one button, no settings", y: 266),
            ], audio: true),
            Simple(title: "Pricing workshop", subject: advisory, daysAgo: 12, paper: Paper(style: .grid), lines: [
                Line(text: "Tiers", y: 90, size: 32),
                Line(text: "Starter    $29", y: 150),
                Line(text: "Team       $99", y: 196),
                Line(text: "Scale      talk to us", y: 242),
            ]),
            Simple(title: "Note Aug 29, 2026", subject: advisory, daysAgo: 26, paper: Paper(style: .blank), lines: [
                Line(text: "call w/ Maya", y: 90, size: 30),
                Line(text: "- eval harness first", y: 150),
                Line(text: "- then the dashboard", y: 196),
            ], audio: true),
            Simple(title: "Q4 roadmap", subject: consulting, daysAgo: 3, paper: Paper(style: .ruled), lines: [
                Line(text: "Q4", y: 92, size: 34),
                Line(text: "1. ship Inkwell phase 1", y: 150),
                Line(text: "2. two new retainers", y: 208),
                Line(text: "3. workshop series", y: 266),
            ]),
            Simple(title: "Hiring loop", subject: consulting, daysAgo: 17, paper: Paper(style: .blank), lines: [
                Line(text: "Hiring loop", y: 90, size: 32),
                Line(text: "- take-home: 3 hrs max", y: 150),
                Line(text: "- pair on a real bug", y: 196),
            ]),
            Simple(title: "Workshop outline", subject: workshops, daysAgo: 9, paper: Paper(style: .dot), lines: [
                Line(text: "Agents 101", y: 92, size: 34),
                Line(text: "1. what an agent is", y: 150),
                Line(text: "2. tools + context", y: 196),
                Line(text: "3. live build", y: 242),
            ], audio: true),
            Simple(title: "Weekly sync", subject: internalSubject, daysAgo: 1, paper: Paper(style: .ruled), lines: [
                Line(text: "Weekly sync", y: 92, size: 32),
                Line(text: "- invoices out Friday", y: 150),
                Line(text: "- renew domains", y: 208),
            ]),
            Simple(title: "Discovery - Northwind", subject: discovery, daysAgo: 4, paper: Paper(style: .blank), lines: [
                Line(text: "Northwind", y: 90, size: 34),
                Line(text: "- 40 reps, all on Salesforce", y: 150),
                Line(text: "- pain: call notes lost", y: 196),
                Line(text: "- budget Q1", y: 242),
            ], audio: true),
        ]
        // PDF-backed note with a typed text box and a pasted image (P1 elements + PDF import).
        do {
            let created = cal.date(byAdding: .day, value: -2, to: now)!
            let note = makeNote(context: context, title: "Workshop agenda", subject: workshops, paper: Paper(), created: created)
            _ = PDFImport.attach(assets.appendingPathComponent("agenda.pdf"), to: note)
            let text = PageElement(kind: .text, frame: CGRect(x: 330, y: 470, width: 230, height: 70))
            text.text = "Bring the Epic Bill transcript as the live demo"
            text.fontSize = 17
            text.colorHex = "#2F6FE4"
            text.isBold = true
            text.frame.size.height = ElementSnapshot.textHeight(text.text!, width: 230, font: .systemFont(ofSize: 17, weight: .semibold))
            context.insert(text)
            note.elements.append(text)
            let image = PageElement(kind: .image, frame: CGRect(x: 330, y: 560, width: 230, height: 146))
            let imgName = "\(image.id.uuidString).jpg"
            if let data = try? Data(contentsOf: assets.appendingPathComponent("chart.png")), let ui = UIImage(data: data),
               let jpg = ui.jpegData(compressionQuality: 0.85) {
                try? jpg.write(to: NoteFiles.imagesFolder(note.id).appendingPathComponent(imgName))
            }
            image.imageFileName = imgName
            context.insert(image)
            note.elements.append(image)
            writeDrawing(note: note, lines: [Line(text: "<- keep this short", x: 330, y: 150, size: 22, color: "#E0343C"),
                                             Line(text: "20 min max", x: 360, y: 300, size: 22, color: "#E0343C")],
                         marks: [], font: font, recordings: [], untimedBase: created)
        }

        for s in simple {
            let created = cal.date(byAdding: .day, value: -s.daysAgo, to: now)!.addingTimeInterval(-3600 * 2)
            let note = makeNote(context: context, title: s.title, subject: s.subject, paper: s.paper, created: created)
            var recs: [Recording] = []
            if s.audio, let short = script.recordings.last {
                recs.append(try makeRecording(context: context, note: note, order: 0, name: "Recording 1",
                                              startedAt: created.addingTimeInterval(600), script: short, assets: assets))
            }
            writeDrawing(note: note, lines: s.lines, marks: [], font: font, recordings: recs, untimedBase: created)
        }
        try context.save()
    }

    // MARK: - Additive demo call (device-safe)

    /// Adds ONE realistic call note and touches nothing else. Unlike INKWELL_DEMO_DIR this never
    /// wipes the store, so it is safe on a device that holds real notes. Trigger: INKWELL_ADD_CALL=1.
    /// Assets ship inside the app bundle (Resources/DemoCall), so no Mac path is involved.
    static func addDemoCall(context: ModelContext) {
        guard env["INKWELL_ADD_CALL"] == "1" else { return }
        guard let assets = Bundle.main.resourceURL else { NSLog("[DEMO] no bundle resourceURL"); return }
        let existing = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        if existing.contains(where: { $0.title == "Client portal rebuild" }) {
            NSLog("[DEMO] call note already present, doing nothing"); return
        }
        do {
            let font = try StrokeFont(url: assets.appendingPathComponent("EMSFelix.json"))
            let script = try JSONDecoder().decode(DemoScript.self,
                            from: Data(contentsOf: assets.appendingPathComponent("call.json")))
            let cal = Calendar.current, now = Date()
            let subject = Subject(name: "Client Work", colorHex: "#2F7D46", sortIndex: 900)
            context.insert(subject)
            let started = cal.date(byAdding: .minute, value: -80, to: now)!
            let note = makeNote(context: context, title: "Client portal rebuild", subject: subject,
                                paper: Paper(style: .blank), created: started.addingTimeInterval(-90))
            let rec = try makeRecording(context: context, note: note, order: 0, name: "Kickoff call",
                                        startedAt: started, script: script.recordings[0], assets: assets)
            let lines: [Line] = [
                Line(text: "Client portal - kickoff", y: 78, size: 34),
                Line(text: "Sep 28  \u{00B7}  Karen, Daniel, me", y: 116, size: 19, color: "#6B6B6B"),
                Line(text: "- launch moves to the 22nd", y: 176, at: (0, 11.0)),
                Line(text: "(design needs another week)", x: 84, y: 214, size: 21, color: "#6B6B6B", at: (0, 15.0)),
                Line(text: "- Karen: onboarding + empty states", y: 262, at: (0, 24.0)),
                Line(text: "! 4,000 old accounts to migrate", y: 322, color: "#E0343C", at: (0, 33.0)),
                Line(text: "-> force reset on first login", x: 84, y: 360, size: 21, color: "#6B6B6B", at: (0, 44.0)),
                Line(text: "- Daniel scoping Thursday", y: 408, at: (0, 50.0)),
                Line(text: "- pricing page: out of scope", y: 456, at: (0, 57.0)),
                Line(text: "Q: own subdomain?", y: 516, color: "#2F6FE4", at: (0, 62.0)),
                Line(text: "TODO  recap by Monday", y: 576, at: (0, 66.0)),
            ]
            let marks: [Mark] = [
                Mark(kind: .highlight, rect: CGRect(x: 50, y: 160, width: 330, height: 26), color: "#FFE14D", at: (0, 13.0)),
                Mark(kind: .underline, rect: CGRect(x: 54, y: 84, width: 262, height: 0), color: "#1A1A1A", at: nil),
            ]
            writeDrawing(note: note, lines: lines, marks: marks, font: font, recordings: [rec],
                         untimedBase: started.addingTimeInterval(-60))
            try context.save()
            NSLog("[DEMO] added 'Client portal rebuild' (%d call lines); %d notes existed before, untouched",
                  script.recordings[0].lines.count, existing.count)
        } catch {
            NSLog("[DEMO] failed: %@", String(describing: error))
        }
    }

    static func makeNote(context: ModelContext, title: String, subject: Subject, paper: Paper, created: Date) -> Note {
        let note = Note(title: title, subject: subject, paper: paper)
        note.createdAt = created
        note.modifiedAt = created.addingTimeInterval(3600)
        context.insert(note)
        return note
    }

    // MARK: - Audio + transcript

    struct DemoScript: Decodable {
        struct Rec: Decodable { var name: String; var lines: [LineAudio] }
        struct LineAudio: Decodable { var voice: String; var text: String; var file: String; var duration: Double }
        var recordings: [Rec]
    }

    /// Concatenates the per-sentence clips (with short pauses) into the recording's capture
    /// file, writes a transcript whose segment times match the audio exactly, then runs the
    /// real transcode path to .m4a.
    static func makeRecording(context: ModelContext, note: Note, order: Int, name: String, startedAt: Date,
                                      script: DemoScript.Rec, assets: URL) throws -> Recording {
        let rec = Recording(note: note, order: order, startedAt: startedAt)
        rec.name = name
        context.insert(rec)
        note.recordings.append(rec)

        let first = try AVAudioFile(forReading: assets.appendingPathComponent(script.lines[0].file))
        let format = first.processingFormat
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        let out = try AVAudioFile(forWriting: NoteFiles.captureURL(noteID: note.id, recordingID: rec.id), settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let gap = 0.6
        var cursor = 0.8
        var segments: [Transcript.Segment] = []
        var voiceLabels: [String: String] = [:]
        func silence(_ seconds: Double) throws {
            let frames = AVAudioFrameCount(seconds * format.sampleRate)
            guard let buf = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: frames) else { return }
            buf.frameLength = frames
            try out.write(from: buf)
        }
        try silence(cursor)
        for line in script.lines {
            let file = try AVAudioFile(forReading: assets.appendingPathComponent(line.file))
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
            try file.read(into: buf)
            try out.write(from: buf)
            let dur = Double(buf.frameLength) / file.processingFormat.sampleRate
            // Word times spread across the sentence by length (demo only; real ones come from SpeechAnalyzer).
            let words = line.text.split(separator: " ").map(String.init)
            let totalChars = Double(words.reduce(0) { $0 + $1.count + 1 })
            var wt = cursor
            var tw: [Transcript.Word] = []
            for w in words {
                let d = dur * Double(w.count + 1) / totalChars
                tw.append(.init(start: wt.rounded2, end: (wt + d).rounded2, text: w))
                wt += d
            }
            // INKWELL_DEMO_SPEAKERS=1: label lines by voice, as cloud speaker detection would.
            var speaker: String?
            if env["INKWELL_DEMO_SPEAKERS"] == "1" {
                if voiceLabels[line.voice] == nil { voiceLabels[line.voice] = "S\(voiceLabels.count + 1)" }
                speaker = voiceLabels[line.voice]
            }
            segments.append(.init(start: cursor.rounded2, end: (cursor + dur).rounded2, text: line.text, words: tw, speaker: speaker))
            cursor += dur
            try silence(gap)
            cursor += gap
        }
        out.close()
        rec.duration = cursor
        let transcript = Transcript(recordingId: rec.id.uuidString, locale: "en-US", engine: "SpeechTranscriber", segments: segments)
        TranscriptStore.save(transcript, noteID: note.id)
        rec.transcriptText = transcript.fullText
        rec.transcriptStatus = .complete
        AudioTranscoder.transcodeCapture(noteID: note.id, recordingID: rec.id, bitRate: 64_000)
        return rec
    }

    // MARK: - Ink

    static func writeDrawing(note: Note, lines: [Line], marks: [Mark], font: StrokeFont,
                                     recordings: [Recording], untimedBase: Date) {
        var rng = SeededRandom(seed: note.title.unicodeScalars.reduce(UInt64(7)) { $0 &* 31 &+ UInt64($1.value) })
        var strokes: [PKStroke] = []
        var untimedCursor = untimedBase
        for line in lines {
            let start: Date
            if let (r, t) = line.at, r < recordings.count {
                start = recordings[r].startedAt.addingTimeInterval(t)
            } else {
                start = untimedCursor
                untimedCursor = untimedCursor.addingTimeInterval(6)
            }
            let width: CGFloat = line.size >= 30 ? 3.0 : 2.5
            strokes += font.strokes(for: line.text, origin: CGPoint(x: line.x, y: line.y), size: line.size,
                                    color: UIColor(hex: line.color), width: width, start: start, rng: &rng)
        }
        for mark in marks {
            let start: Date
            if let (r, t) = mark.at, r < recordings.count { start = recordings[r].startedAt.addingTimeInterval(t) }
            else { start = untimedCursor }
            strokes.append(markStroke(mark, start: start, rng: &rng))
            if mark.kind == .highlight {
                // Real highlighting is two passes; where they overlap the ink is denser.
                var second = mark
                second.rect = mark.rect.insetBy(dx: CGFloat(rng.next(8, 26)), dy: 1.5)
                    .offsetBy(dx: CGFloat(rng.next(-6, 6)), dy: CGFloat(rng.next(-1.5, 1.5)))
                strokes.append(markStroke(second, start: start.addingTimeInterval(0.35), rng: &rng))
            }
        }
        let drawing = PKDrawing(strokes: strokes)
        DrawingStore.save(drawing, noteID: note.id)
        let geo = PageGeometry(paper: note.paper)
        note.pageCount = max(note.pageCount, geo.pagesNeeded(forMaxY: drawing.bounds.isNull ? 0 : drawing.bounds.maxY))
        let pdf = note.pdfBackgroundFile.flatMap { CGPDFDocument(NoteFiles.folder(note.id).appendingPathComponent($0) as CFURL) }
        let images = note.elements.compactMap { e -> ElementSnapshot? in
            let img = e.imageFileName.flatMap { UIImage(contentsOfFile: NoteFiles.imagesFolder(note.id).appendingPathComponent($0).path) }
            return ElementSnapshot(id: e.id, kind: e.kind, frame: e.frame, text: e.text ?? "", fontSize: CGFloat(e.fontSize ?? 16),
                                   isBold: e.isBold ?? false, colorHex: e.colorHex ?? "#1A1A1A", image: img, createdAt: e.createdAt)
        }
        ThumbnailRenderer.render(drawing: drawing, paper: note.paper, noteID: note.id, pdf: pdf, elements: images)
        note.thumbnailVersion += 1
    }

    private static func markStroke(_ mark: Mark, start: Date, rng: inout SeededRandom) -> PKStroke {
        let r = mark.rect
        var pts: [CGPoint] = []
        let ink: PKInk
        let width: CGFloat
        switch mark.kind {
        case .highlight:
            // A real highlighter sweep is tilted, overshoots the words, varies in width along the
            // stroke, and lets the text read through it. A constant-width, fully opaque, perfectly
            // level bar is the thing that reads as fake.
            ink = PKInk(.marker, color: UIColor(hex: mark.color).withAlphaComponent(0.85))
            width = r.height
            let lead = CGFloat(rng.next(5, 11))          // starts before the first word
            let tail = CGFloat(rng.next(-4, 9))          // and stops a little past or short of the last
            let tilt = CGFloat(rng.next(-2.2, 1.4))      // the hand sweeps on a slight angle
            let phase = rng.next(0, 6.28)
            pts = stride(from: 0.0, through: 1.0, by: 0.035).map { t -> CGPoint in
                let x = r.minX - lead + (r.width + lead + tail) * CGFloat(t)
                let wobble = sin(CGFloat(t) * 2.6 + CGFloat(phase)) * 1.5 + CGFloat(rng.next(-0.5, 0.5))
                return CGPoint(x: x, y: r.midY + tilt * CGFloat(t) + wobble)
            }
        case .underline:
            ink = PKInk(.pen, color: UIColor(hex: mark.color))
            width = 2.2
            pts = stride(from: 0.0, through: 1.0, by: 0.05).map { CGPoint(x: r.minX + r.width * $0, y: r.minY + 12 + CGFloat(sin($0 * 3) * 1.5)) }
        case .box:
            ink = PKInk(.pen, color: UIColor(hex: mark.color))
            width = 2.2
            let corners = [CGPoint(x: r.minX + 4, y: r.minY), CGPoint(x: r.maxX, y: r.minY + 2),
                           CGPoint(x: r.maxX - 2, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - 1), CGPoint(x: r.minX + 6, y: r.minY - 3)]
            for i in 0..<(corners.count - 1) {
                for s in stride(from: 0.0, to: 1.0, by: 0.1) {
                    let a = corners[i], b = corners[i + 1]
                    pts.append(CGPoint(x: a.x + (b.x - a.x) * s + CGFloat(rng.next(-0.5, 0.5)), y: a.y + (b.y - a.y) * s))
                }
            }
        }
        let n = max(1, pts.count - 1)
        let points = pts.enumerated().map { i, p -> PKStrokePoint in
            var w = width
            var force: CGFloat = 1
            if mark.kind == .highlight {
                // Taper in at the start, fatten through the middle, thin out at the lift.
                let t = CGFloat(i) / CGFloat(n)
                let body = 0.97 + 0.06 * sin(t * .pi)
                let ends = min(1, t / 0.030) * min(1, (1 - t) / 0.035)
                w = width * (0.96 + 0.04 * ends) * body
                force = 0.90 + 0.10 * ends
            }
            return PKStrokePoint(location: p, timeOffset: Double(i) * 0.012, size: CGSize(width: w, height: w),
                                 opacity: 1, force: force, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: start))
    }

    // MARK: - Launch state for screenshots

    @MainActor
    static func applyLaunchState(model: AppModel) {
        guard let screen = env["INKWELL_SCREEN"] else { return }
        let ctx = model.context
        let notes = (try? ctx.fetch(FetchDescriptor<Note>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]))) ?? []
        let subjects = (try? ctx.fetch(FetchDescriptor<Subject>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        let main = notes.first { $0.title == "Launch sync" } ?? notes.first
        if let s = subjects.first { model.selection = .subject(s.id) }

        func openMain(library: Bool) {
            if let main { model.open(main) }
            model.libraryVisible = library
            // Opening a note closes the slide-over library in portrait; reopen it after that.
            if library {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    model.libraryVisible = true
                }
            }
        }

        switch screen {
        case "library":
            openMain(library: true)
        case "library-all":
            model.selection = .all
            openMain(library: true)
        case "library-empty":
            model.selection = .all
        case "editor-empty":
            model.libraryVisible = true
            model.createNote()
        case "editor-ink":
            openMain(library: false)
            ToolState.shared.current = .pen
            model.editor?.subBarVisible = false
        case "pen", "pencil", "highlighter", "eraser", "lasso":
            openMain(library: false)
            ToolState.shared.current = ToolKind(rawValue: screen) ?? .pen
            model.editor?.subBarVisible = true
            model.editor?.applyTool()
        case "paper-sheet":
            openMain(library: false)
            model.editor?.showPaperSheet = true
        case "search":
            openMain(library: true)
            model.isSearching = true
            model.searchText = env["INKWELL_QUERY"] ?? "webhooks"
        case "pages":
            openMain(library: false)
            model.editor?.rail = .pages
        case "rec-empty":
            if let n = notes.first(where: { $0.title == "Q4 roadmap" }) { model.open(n) }
            model.libraryVisible = false
            model.editor?.rail = .recordings
        case "rec-idle":
            openMain(library: false)
            model.editor?.rail = .recordings
        case "rec-playing", "replay":
            // INKWELL_LIBRARY=1 keeps the sidebar + note list open alongside the recordings panel.
            openMain(library: env["INKWELL_LIBRARY"] == "1")
            if screen == "rec-playing" { model.editor?.rail = .recordings }
            let t = Double(env["INKWELL_T"] ?? "") ?? 24
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                guard let editor = model.editor else { return }
                await editor.reloadAudio()
                editor.playback.seek(to: t)
                // Select the recording the playhead is inside, otherwise the transcript panel shows a
                // different recording than the transport and no line tracks the audio.
                var acc = 0.0
                for rec in editor.note.recordings.sorted(by: { $0.startedAt < $1.startedAt }) {
                    if t < acc + rec.duration { editor.selectedRecordingID = rec.id; break }
                    acc += rec.duration
                }
                if env["INKWELL_PLAY"] == "1" { editor.playback.play() }
            }
        case "elements", "text-edit", "single-page":
            if let n = notes.first(where: { $0.title == "Workshop agenda" }) { model.open(n) }
            model.libraryVisible = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                guard let editor = model.editor else { return }
                if screen == "single-page" {
                    editor.setViewMode(.singlePage)
                    return
                }
                let kind: ElementKind = screen == "elements" ? .image : .text
                ToolState.shared.current = kind == .image ? .lasso : .text
                editor.subBarVisible = true
                editor.applyTool()
                if let e = editor.note.elements.first(where: { $0.kind == kind }) {
                    editor.selectElement(e.id, editText: kind == .text)
                }
            }
        case "new-subject":
            model.selection = .all
            openMain(library: true)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                model.requestNewSubject = true
            }
        case "rec-live", "rec-bar":
            openMain(library: false)
            if screen == "rec-live" { model.editor?.rail = .recordings }
            model.editor?.subBarVisible = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                model.editor?.toggleRecording()
            }
        case "restore":
            model.settingsSection = .backup
            model.showSettings = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                await BackupEngine.shared.restore()
            }
        case "settings":
            openMain(library: true)
            model.settingsSection = SettingsSection(rawValue: env["INKWELL_SECTION"] ?? "") ?? .document
            model.showSettings = true
        default:
            break
        }
    }
}

// MARK: - Single-stroke font

struct StrokeFont {
    struct Glyph: Decodable { var adv: Double; var strokes: [[[Double]]] }
    struct File: Decodable { var unitsPerEm: Double; var glyphs: [String: Glyph] }
    let file: File

    init(url: URL) throws {
        file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    /// Lays out `text` with its baseline at origin.y. Each glyph stroke becomes a PKStroke,
    /// timestamped ~90 ms apart from `start`, like real writing.
    func strokes(for text: String, origin: CGPoint, size: CGFloat, color: UIColor, width: CGFloat,
                 start: Date, rng: inout SeededRandom) -> [PKStroke] {
        let s = size / file.unitsPerEm
        var x = origin.x
        var t = start
        var out: [PKStroke] = []
        let ink = PKInk(.pen, color: color)
        // Real handwriting never repeats a letter exactly. Give every glyph its own small
        // rotation, scale, slant and pen weight, and let the baseline wander across the line,
        // so no two instances of the same character are identical.
        var drift = 0.0
        let driftRate = rng.next(-0.010, 0.010)
        for ch in text {
            guard let g = file.glyphs[String(ch)] else { x += 300 * s; continue }
            drift += driftRate + rng.next(-0.022, 0.022)
            drift = max(-1.6, min(1.6, drift))
            let dy = CGFloat(rng.next(-0.55, 0.55) + drift)
            let slant = 0.08 + rng.next(-0.035, 0.035)
            let rot = CGFloat(rng.next(-0.028, 0.028))          // ~1.6 degrees
            let gs = s * CGFloat(rng.next(0.968, 1.032))        // per-letter size variance
            let gw = width * CGFloat(rng.next(1.00, 1.14))      // per-letter pen weight, never thinner than base
            let cosR = cos(rot), sinR = sin(rot)
            for poly in g.strokes where poly.count >= 2 {
                // PKStrokePath treats points as B-spline control points, so sparse polyline
                // vertices get rounded off. Densify to ~0.8 pt so the curve follows the glyph.
                let vertices = poly.map { p -> CGPoint in
                    // glyph space -> slanted, scaled, then rotated about the glyph origin
                    let gx = CGFloat(p[0] + slant * p[1]) * gs
                    let gy = -CGFloat(p[1]) * gs
                    return CGPoint(x: x + gx * cosR - gy * sinR,
                                   y: origin.y + gx * sinR + gy * cosR + dy)
                }
                var dense: [CGPoint] = [vertices[0]]
                for k in 1..<vertices.count {
                    let a = vertices[k - 1], b = vertices[k]
                    let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 0.8))
                    for j in 1...n {
                        let f = CGFloat(j) / CGFloat(n)
                        dense.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                    }
                }
                // Constant force at a realistic writing speed (~40 pt/s): PencilKit's pen thins
                // fast or light segments to hairlines, which made retraced strokes vanish.
                let pts = dense.enumerated().map { i, loc in
                    PKStrokePoint(location: loc, timeOffset: Double(i) * 0.02,
                                  size: CGSize(width: gw, height: gw),
                                  opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                out.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: t)))
                t = t.addingTimeInterval(0.09)
            }
            x += CGFloat(g.adv) * gs * 0.92 + CGFloat(rng.next(-0.75, 0.75))
        }
        return out
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func nextUnit() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
    mutating func next(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * nextUnit() }
}
#endif
