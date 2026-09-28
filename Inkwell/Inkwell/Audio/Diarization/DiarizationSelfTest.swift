import AVFoundation
import Foundation

/// Rebuilds the bundled three-voice demo call — 0.8 s of lead-in, each line, 0.6 s between,
/// exactly as `DemoSeeder.makeRecording` concatenates it — into a throwaway file in the temp
/// directory, along with segment times that match. Used by the unit tests and by the
/// `INKWELL_DIARIZE_DEMO=1` self-test. It never touches the note store.
nonisolated enum DemoCallFixture {
    struct Fixture {
        var url: URL
        var segments: [Transcript.Segment]
        var voices: [String]
    }

    private struct Script: Decodable {
        struct Rec: Decodable { var lines: [Line] }
        struct Line: Decodable { var voice: String; var text: String; var file: String }
        var recordings: [Rec]
    }

    static func build() -> Fixture? {
        guard let assets = Bundle.main.resourceURL,
              let data = try? Data(contentsOf: assets.appendingPathComponent("call.json")),
              let script = try? JSONDecoder().decode(Script.self, from: data),
              let lines = script.recordings.first?.lines, !lines.isEmpty else { return nil }
        do {
            let first = try AVAudioFile(forReading: assets.appendingPathComponent(lines[0].file))
            let format = first.processingFormat
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("democall-\(UUID().uuidString).wav")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                                           AVSampleRateKey: format.sampleRate,
                                           AVNumberOfChannelsKey: 1,
                                           AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false]
            let out = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            func silence(_ seconds: Double) throws {
                let frames = AVAudioFrameCount(seconds * format.sampleRate)
                guard let buf = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: frames) else { return }
                buf.frameLength = frames
                try out.write(from: buf)
            }
            var cursor = 0.8
            var segments: [Transcript.Segment] = []
            var voices: [String] = []
            try silence(cursor)
            for line in lines {
                let file = try AVAudioFile(forReading: assets.appendingPathComponent(line.file))
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)) else { continue }
                try file.read(into: buf)
                try out.write(from: buf)
                let dur = Double(buf.frameLength) / file.processingFormat.sampleRate
                segments.append(Transcript.Segment(start: cursor, end: cursor + dur, text: line.text,
                                                   words: [], speaker: nil))
                voices.append(line.voice)
                cursor += dur
                try silence(0.6)
                cursor += 0.6
            }
            out.close()
            return Fixture(url: url, segments: segments, voices: voices)
        } catch {
            NSLog("[DIAR] fixture failed: %@", String(describing: error))
            return nil
        }
    }
}

/// `INKWELL_DIARIZE_DEMO=1` at launch: diarizes the bundled demo call on this device and logs
/// the labels, the accuracy against the known voices, and how long it took. Reads nothing but
/// the app bundle and writes nothing but a temp file, so it is safe to run on Pat's iPad.
nonisolated enum DiarizationSelfTest {
    /// Ground truth: Reed → S1, Karen → S2, Daniel → S3, in order of first appearance.
    static let expected = ["S1", "S2", "S1", "S3", "S2", "S1", "S3", "S2", "S1", "S3", "S2", "S1", "S3", "S1"]

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["INKWELL_DIARIZE_DEMO"] == "1" else { return }
        Task.detached(priority: .userInitiated) {
            guard let fixture = DemoCallFixture.build() else { NSLog("[DIAR] no demo assets"); return }
            defer { try? FileManager.default.removeItem(at: fixture.url) }
            NSLog("[DIAR] --- on-device diarization self-test ---")
            NSLog("[DIAR] model bundled: %@", SpeakerEmbedder.isBundled ? "yes" : "NO")
            // Warm the model first, then time the run the way a real recording would see it.
            for pass in 1...2 {
                do {
                    let r = try LocalDiarizer.diarize(audioURL: fixture.url, segments: fixture.segments)
                    let got = r.labels.map { $0 ?? "-" }
                    let correct = zip(got, expected).filter { $0 == $1 }.count
                    NSLog("[DIAR] pass %d: %@", pass, got.joined(separator: "|"))
                    NSLog("[DIAR] pass %d: %d/%d segments correct, %d speakers found (expected 3)",
                          pass, correct, expected.count, r.speakerCount)
                    NSLog("[DIAR] pass %d: %.2f s of work for %.1f s of audio (%.1f s of speech, %d windows) = %.0fx realtime",
                          pass, r.elapsedSeconds, r.audioSeconds, r.speechSeconds, r.windows,
                          r.audioSeconds / max(r.elapsedSeconds, 0.001))
                } catch {
                    NSLog("[DIAR] pass %d FAILED: %@", pass, String(describing: error))
                }
            }
        }
    }
}
