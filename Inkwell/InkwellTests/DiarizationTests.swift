import AVFoundation
import CoreML
import XCTest
@testable import Inkwell

/// On-device speaker diarization (`LocalDiarizer`).
///
/// The numbers in `Reference` come from the Python conversion harness
/// (`tools/diarization/`) run on the same deterministic signal generated below:
/// `torchaudio.compliance.kaldi.fbank` for the filterbank, and the original PyTorch
/// WeSpeaker ResNet-34 for the embedding. If the Swift filterbank or the Core ML model
/// ever drifts from what the model was trained on, these fail.
final class DiarizationTests: XCTestCase {
    private enum Reference {
        static let frames = 298
        static let frame0 = [13.1835, 14.9844, 18.7916, 19.4799, 19.3967, 18.6772, 16.5768, 18.7124] as [Float]
        static let frame97 = [12.8866, 10.9443, 11.958, 13.2305, 14.3775, 15.2664, 18.505, 20.9284] as [Float]
        static let frame97Tail = [20.3647, 20.7482, 20.1931, 20.2531] as [Float]
        static let frame250 = [17.1938, 18.4977, 20.6867, 20.9903, 20.9049, 20.3486, 19.0244, 20.3592] as [Float]
        static let frame250Tail = [19.9977, 20.8739, 20.7929, 21.2679] as [Float]
        static let embedding12: [Float] = [-0.01931, 0.028669, 0.050289, -0.079973, 0.04508, -0.027071,
                                           -0.055514, 0.011252, 0.083998, 0.039248, 0.040669, 0.068572]
    }

    /// Three seconds of a voice-like signal: a moving pitch with harmonics, a syllable
    /// envelope, a chirp, and a broadband hiss from a fixed-seed xorshift so every Mel bin
    /// carries real energy. Deterministic, so Python and Swift see the same samples.
    private func testSignal(seconds: Double = 3) -> [Float] {
        let n = Int(16_000 * seconds)
        var state: UInt32 = 2_463_534_242
        func hiss() -> Double {
            state ^= state &<< 13
            state ^= state >> 17
            state ^= state &<< 5
            return Double(state) / Double(UInt32.max) * 2 - 1
        }
        return (0..<n).map { i in
            let t = Double(i) / 16_000
            let env = 0.35 + 0.65 * abs(sin(2 * .pi * 1.7 * t))
            let f0 = 120.0 + 40.0 * sin(2 * .pi * 0.9 * t)
            var v = 0.0
            for h in [1.0, 2.0, 3.0, 5.0, 8.0] { v += (0.7 / h) * sin(2 * .pi * f0 * h * t + 0.3 * h) }
            v += 0.05 * sin(2 * .pi * (600.0 + 1800.0 * t) * t)
            return Float(env * (v * 0.35 + 0.02 * hiss()))
        }
    }

    // MARK: - Filterbank

    func testFilterbankMatchesKaldi() {
        let feats = KaldiFBank().features(from: testSignal())
        XCTAssertEqual(feats.rows, Reference.frames)
        XCTAssertEqual(feats.cols, 80)
        for (i, expected) in Reference.frame0.enumerated() {
            XCTAssertEqual(feats[0, i], expected, accuracy: 0.002, "frame 0 bin \(i)")
        }
        for (i, expected) in Reference.frame97.enumerated() {
            XCTAssertEqual(feats[97, i], expected, accuracy: 0.002, "frame 97 bin \(i)")
        }
        for (i, expected) in Reference.frame97Tail.enumerated() {
            XCTAssertEqual(feats[97, 76 + i], expected, accuracy: 0.002, "frame 97 tail bin \(i)")
        }
        for (i, expected) in Reference.frame250.enumerated() {
            XCTAssertEqual(feats[250, i], expected, accuracy: 0.002, "frame 250 bin \(i)")
        }
        for (i, expected) in Reference.frame250Tail.enumerated() {
            XCTAssertEqual(feats[250, 76 + i], expected, accuracy: 0.002, "frame 250 tail bin \(i)")
        }
    }

    func testFrameCountFollowsSnipEdges() {
        XCTAssertEqual(KaldiFBank.frameCount(sampleCount: 399), 0)
        XCTAssertEqual(KaldiFBank.frameCount(sampleCount: 400), 1)
        XCTAssertEqual(KaldiFBank.frameCount(sampleCount: 559), 1)
        XCTAssertEqual(KaldiFBank.frameCount(sampleCount: 560), 2)
        XCTAssertEqual(KaldiFBank.frameCount(sampleCount: 16_000), 98)
    }

    // MARK: - Core ML model

    func testCoreMLEmbeddingMatchesPyTorch() throws {
        XCTAssertTrue(SpeakerEmbedder.isBundled, "SpeakerEmbedding.mlmodelc is not in the app bundle")
        let feats = KaldiFBank().features(from: testSignal())
        // The CPU path is the one that lines up with PyTorch; the ANE trades accuracy for speed.
        let embedder = try SpeakerEmbedder(computeUnits: .cpuOnly)
        let window = LocalDiarizer.window(feats, from: .init(start: 0, end: 2.0))
        let out = try embedder.embed(windows: [window])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].count, 256)
        var dot: Float = 0, refNorm: Float = 0
        for (i, r) in Reference.embedding12.enumerated() { dot += out[0][i] * r; refNorm += r * r }
        // Only the first 12 dimensions are pinned; check they point the same way and agree.
        XCTAssertGreaterThan(dot, 0)
        for (i, expected) in Reference.embedding12.enumerated() {
            XCTAssertEqual(out[0][i], expected, accuracy: 0.01, "dim \(i)")
        }
        XCTAssertEqual(sqrt(out[0].reduce(0) { $0 + $1 * $1 }), 1.0, accuracy: 1e-4, "embeddings must be L2-normalised")
        XCTAssertGreaterThan(refNorm, 0)
    }

    /// Two windows of one real voice must sit closer than the merge threshold, and a window of
    /// a different voice must sit further away. Uses the bundled call: 0.8–5.95 s and
    /// 12.92–17.96 s are Reed, 6.55–12.32 s is Karen.
    func testSameVoiceIsCloserThanADifferentVoice() throws {
        let call = try XCTUnwrap(DemoCallFixture.build())
        defer { try? FileManager.default.removeItem(at: call.url) }
        let feats = KaldiFBank().features(from: try LocalDiarizer.monoSamples16k(url: call.url))
        let embedder = try SpeakerEmbedder(computeUnits: .cpuOnly)
        let out = try embedder.embed(windows: [
            LocalDiarizer.window(feats, from: .init(start: 1.2, end: 3.2)),    // Reed
            LocalDiarizer.window(feats, from: .init(start: 13.5, end: 15.5)),  // Reed again
            LocalDiarizer.window(feats, from: .init(start: 7.5, end: 9.5)),    // Karen
        ])
        func distance(_ a: [Float], _ b: [Float]) -> Float { 1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        let same = distance(out[0], out[1])
        let different = distance(out[0], out[2])
        print("[DIAR] same-voice distance \(same), different-voice distance \(different)")
        XCTAssertLessThan(same, LocalDiarizer.mergeThreshold, "one voice must fall inside the threshold")
        XCTAssertGreaterThan(different, LocalDiarizer.mergeThreshold, "two voices must fall outside it")
    }

    func testSingletonClustersAreFoldedIntoTheNearestVoice() {
        func point(_ base: Int, _ jitter: Float) -> [Float] {
            var v = [Float](repeating: 0, count: 256)
            v[base] = 1
            v[(base + 1) % 256] = jitter
            return SpeakerEmbedder.l2Normalised(v)
        }
        // Two real voices plus one stray window that clustered on its own.
        let embs = [point(0, 0.02), point(0, 0.04), point(64, 0.01), point(64, 0.03), point(0, 0.25)]
        let labels = [0, 0, 1, 1, 2]
        let pruned = LocalDiarizer.pruneSingletons(labels, embeddings: embs)
        XCTAssertEqual((pruned.max() ?? -1) + 1, 2, "the stray stops counting as a third speaker")
        XCTAssertEqual(pruned[4], pruned[0], "it joins the voice it sits nearest")
        // Nothing to prune: labels come back untouched.
        XCTAssertEqual(LocalDiarizer.pruneSingletons([0, 0, 1, 1], embeddings: Array(embs.prefix(4))), [0, 0, 1, 1])
        XCTAssertEqual(LocalDiarizer.pruneSingletons([0, 1, 2], embeddings: Array(embs.prefix(3))), [0, 1, 2],
                       "all-singletons is left alone rather than collapsed to one speaker")
    }

    // MARK: - Speech detection, windowing, clustering

    func testSpeechMaskFindsSpeechAndSkipsSilence() {
        var samples = [Float](repeating: 0, count: 16_000)          // 1.0 s of silence
        samples += testSignal(seconds: 2)                           // 2.0 s of "speech"
        samples += [Float](repeating: 0, count: 16_000)             // 1.0 s of silence
        let feats = KaldiFBank().features(from: samples)
        let regions = LocalDiarizer.speechRegions(LocalDiarizer.speechMask(feats))
        XCTAssertEqual(regions.count, 1, "one contiguous speech region")
        let r = try? XCTUnwrap(regions.first)
        XCTAssertEqual(r?.start ?? 0, 1.0, accuracy: 0.25)
        XCTAssertEqual(r?.end ?? 0, 3.0, accuracy: 0.25)
    }

    func testWindowsCoverRegionsWithoutRunningPast() {
        let regions = [LocalDiarizer.Window(start: 0, end: 5.0),
                       LocalDiarizer.Window(start: 10.0, end: 10.3),      // too short to embed
                       LocalDiarizer.Window(start: 20.0, end: 21.2)]      // shorter than one window
        let wins = LocalDiarizer.windows(in: regions)
        XCTAssertFalse(wins.contains { $0.start < 0 })
        XCTAssertFalse(wins.contains { $0.start >= 10.0 && $0.end <= 10.3 }, "sub-0.6 s regions are skipped")
        XCTAssertTrue(wins.contains { $0.start == 20.0 && $0.end == 21.2 }, "short regions pass through whole")
        for w in wins where w.start < 6 { XCTAssertLessThanOrEqual(w.end, 5.0) }
        XCTAssertGreaterThan(wins.filter { $0.end <= 5.0 }.count, 3, "a 5 s region yields several windows")
    }

    func testShortWindowIsTiledToTheModelInputLength() {
        let feats = KaldiFBank().features(from: testSignal())
        let w = LocalDiarizer.window(feats, from: .init(start: 0.0, end: 0.7))
        XCTAssertEqual(w.count, SpeakerEmbedder.windowFrames * 80)
        // Mean-normalised: every Mel bin averages zero across the window.
        for c in stride(from: 0, to: 80, by: 17) {
            var sum: Float = 0
            for r in 0..<SpeakerEmbedder.windowFrames { sum += w[r * 80 + c] }
            XCTAssertEqual(sum / Float(SpeakerEmbedder.windowFrames), 0, accuracy: 1e-3, "bin \(c)")
        }
    }

    func testClusteringInfersSpeakerCount() {
        func unit(_ v: [Float]) -> [Float] { SpeakerEmbedder.l2Normalised(v) }
        func point(_ base: Int, _ jitter: Float) -> [Float] {
            var v = [Float](repeating: 0, count: 256)
            v[base] = 1
            v[(base + 1) % 256] = jitter
            return unit(v)
        }
        // Three tight groups, far apart: three speakers, no count passed in.
        let embs = [point(0, 0.02), point(0, 0.05), point(0, -0.03),
                    point(64, 0.01), point(64, 0.04),
                    point(128, -0.02), point(128, 0.03)]
        let labels = LocalDiarizer.clusterLabels(embs, threshold: LocalDiarizer.mergeThreshold)
        XCTAssertEqual((labels.max() ?? -1) + 1, 3)
        XCTAssertEqual(labels, [0, 0, 0, 1, 1, 2, 2])

        // One group: one speaker.
        let solo = [point(0, 0.01), point(0, 0.03), point(0, -0.02), point(0, 0.0)]
        XCTAssertEqual(LocalDiarizer.clusterLabels(solo, threshold: LocalDiarizer.mergeThreshold), [0, 0, 0, 0])
        XCTAssertEqual(LocalDiarizer.clusterLabels([], threshold: 0.6), [])
        XCTAssertEqual(LocalDiarizer.clusterLabels([point(0, 0)], threshold: 0.6), [0])
    }

    func testSegmentsTakeTheClusterThatOwnsTheirAirtime() {
        let segs = [seg(0, 2), seg(2, 4), seg(4, 6), seg(30, 31)]
        let wins = [LocalDiarizer.Window(start: 0, end: 2),
                    LocalDiarizer.Window(start: 2, end: 4),
                    LocalDiarizer.Window(start: 3.5, end: 6)]
        let assigned = LocalDiarizer.assign(segments: segs, windows: wins, windowLabels: [0, 1, 1], clusters: 2)
        XCTAssertEqual(assigned, [0, 1, 1, 1], "the unvoiced segment falls back to the nearest window")
        let names = LocalDiarizer.speakerNames(for: assigned, clusters: 2)
        XCTAssertEqual(names[0], "S1")
        XCTAssertEqual(names[1], "S2")
    }

    func testSpeakerNamesNumberByFirstAppearance() {
        // Cluster 2 speaks first, so it must be "S1".
        let names = LocalDiarizer.speakerNames(for: [2, 0, 2, 1], clusters: 3)
        XCTAssertEqual(names[2], "S1")
        XCTAssertEqual(names[0], "S2")
        XCTAssertEqual(names[1], "S3")
    }

    // MARK: - End to end, against the cloud's answer on the bundled demo call

    /// The bundled 3-voice call, concatenated exactly as `DemoSeeder` does, run end to end.
    /// The cloud (ElevenLabs Scribe v2) labels this call Reed → S1, Karen → S2, Daniel → S3,
    /// i.e. per line: S1 S2 S1 S3 S2 S1 S3 S2 S1 S3 S2 S1 S3 S1. That is the ground truth.
    func testDemoCallLabelsMatchTheCloud() throws {
        let call = try XCTUnwrap(DemoCallFixture.build(), "demo call assets missing from the bundle")
        defer { try? FileManager.default.removeItem(at: call.url) }
        let result = try LocalDiarizer.diarize(audioURL: call.url, segments: call.segments)
        let expected = DiarizationSelfTest.expected
        let got = result.labels.map { $0 ?? "-" }
        let correct = zip(got, expected).filter { $0 == $1 }.count
        print("[DIAR] labels   \(got.joined(separator: "|"))")
        print("[DIAR] expected \(expected.joined(separator: "|"))")
        print("[DIAR] \(correct)/\(expected.count) segments, \(result.speakerCount) speakers, "
              + "\(result.windows) windows, \(String(format: "%.2f", result.elapsedSeconds)) s "
              + "for \(String(format: "%.1f", result.audioSeconds)) s of audio")
        XCTAssertEqual(result.speakerCount, 3, "three voices in the call")
        XCTAssertEqual(got, expected)
    }

    private func seg(_ start: Double, _ end: Double) -> Transcript.Segment {
        Transcript.Segment(start: start, end: end, text: "x", words: [], speaker: nil)
    }
}
