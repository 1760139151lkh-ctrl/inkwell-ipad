import AVFoundation
import Accelerate
import Foundation

/// On-device speaker diarization. Nothing leaves the iPad and nothing is billed.
///
/// The shape of it:
///  1. decode the recording to 16 kHz mono and compute a Kaldi log-Mel filterbank;
///  2. mark the frames that carry speech (an adaptive energy gate, smoothed);
///  3. slide 2-second windows across the speech and turn each one into a 256-d voiceprint
///     with the bundled WeSpeaker ResNet-34 (`SpeakerEmbedder`);
///  4. cluster the voiceprints with average-linkage agglomerative clustering, stopping at a
///     cosine-distance threshold — so the number of speakers is inferred, never passed in;
///  5. give each transcript segment the cluster that owns the most of its airtime, and number
///     the clusters "S1", "S2", … in order of first appearance, matching the cloud's labels.
nonisolated struct LocalDiarizer {
    // MARK: Tuning

    /// Cosine distance at which two clusters stop being the same person. Swept over six cases
    /// (one voice, two similar male voices, three voices clean, three voices through 64 kbps
    /// AAC, five voices, and a run of one-word turns): together with the singleton pruning
    /// below, 0.40–0.56 all give the right speaker count on five of the six, so 0.50 sits in
    /// the middle rather than on an edge. See `tools/diarization/README.md`.
    static let mergeThreshold: Float = 0.50
    /// A real speaker gets more than one 2-second window, so a cluster holding exactly one is
    /// almost always a stray — a door, a laugh, a clipped word — and inflates the speaker
    /// count. Those get folded into the nearest surviving voice. Skipped when the whole
    /// recording only produced a handful of windows, where a singleton may be a real person.
    static let minWindowsForPruning = 12
    static let windowSeconds = 2.0
    static let baseHopSeconds = 0.75
    static let maxHopSeconds = 2.0
    /// Above this the clustering is done on a uniform subsample and the rest assigned to the
    /// nearest centroid, so an hour-long meeting stays bounded in time and memory.
    static let maxClusteringWindows = 1_500
    /// Speech shorter than this can't carry a usable voiceprint.
    static let minWindowSeconds = 0.60

    struct Window: Equatable {
        var start: Double
        var end: Double
    }

    struct Result {
        /// One entry per input transcript segment, "S1"/"S2"/… or nil if it held no speech.
        var labels: [String?]
        var speakerCount: Int
        var windows: Int
        var audioSeconds: Double
        var speechSeconds: Double
        var elapsedSeconds: Double
    }

    enum Failure: LocalizedError {
        case noAudio
        case tooShort

        var errorDescription: String? {
            switch self {
            case .noAudio: "Couldn't read this recording's audio."
            case .tooShort: "This recording is too short to tell voices apart."
            }
        }
    }

    // MARK: - Entry point

    /// Labels `segments` in place of the cloud. Runs synchronously; call it off the main actor.
    static func diarize(audioURL: URL, segments: [Transcript.Segment],
                        embedder: SpeakerEmbedder? = nil) throws -> Result {
        let clock = Date()
        let samples = try monoSamples16k(url: audioURL)
        let audioSeconds = Double(samples.count) / KaldiFBank.sampleRate
        guard samples.count >= Int(KaldiFBank.sampleRate * minWindowSeconds) else { throw Failure.tooShort }

        let feats = KaldiFBank().features(from: samples)
        guard feats.rows > 0 else { throw Failure.tooShort }

        let mask = speechMask(feats)
        let regions = speechRegions(mask)
        let speech = regions.reduce(0.0) { $0 + ($1.end - $1.start) }
        let hop = min(maxHopSeconds, max(baseHopSeconds, speech / Double(maxClusteringWindows)))
        let wins = windows(in: regions, hop: hop)
        guard !wins.isEmpty else { throw Failure.tooShort }

        let model = try embedder ?? SpeakerEmbedder()
        let embeddings = try model.embed(windows: wins.map { window(feats, from: $0) })
        var labels = clusterLabels(embeddings, threshold: mergeThreshold)
        if wins.count >= minWindowsForPruning { labels = pruneSingletons(labels, embeddings: embeddings) }
        let count = (labels.max() ?? -1) + 1
        let assigned = assign(segments: segments, windows: wins, windowLabels: labels, clusters: count)
        let names = speakerNames(for: assigned, clusters: count)

        return Result(labels: assigned.map { $0 >= 0 ? names[$0] : nil },
                      speakerCount: Set(assigned.filter { $0 >= 0 }).count,
                      windows: wins.count,
                      audioSeconds: audioSeconds,
                      speechSeconds: speech,
                      elapsedSeconds: Date().timeIntervalSince(clock))
    }

    // MARK: - Audio

    /// Decodes any recording Inkwell writes (.m4a or the .caf capture) to 16 kHz mono float.
    static func monoSamples16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: KaldiFBank.sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw Failure.noAudio }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let readChunk: AVAudioFrameCount = 16_384
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: readChunk) else { throw Failure.noAudio }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(readChunk) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { throw Failure.noAudio }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio) + 1024)
        var finished = false
        while !finished {
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                do {
                    try file.read(into: inBuffer, frameCount: readChunk)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let error { throw error }
            if outBuffer.frameLength > 0, let ch = outBuffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error { finished = true }
            outBuffer.frameLength = 0
        }
        guard !samples.isEmpty else { throw Failure.noAudio }
        return samples
    }

    // MARK: - Speech detection

    /// Per-frame speech flag. The gate sits a fixed fraction of the way up this recording's
    /// own quiet-to-loud range, so it adapts to how loudly the room was recorded; short
    /// gaps are then closed and short bursts dropped so a breath doesn't split a sentence.
    static func speechMask(_ feats: KaldiFBank.Matrix, thresholdFraction: Float = 0.45,
                           minSpeech: Double = 0.20, minSilence: Double = 0.20) -> [Bool] {
        guard feats.rows > 0 else { return [] }
        var energy = [Float](repeating: 0, count: feats.rows)
        for i in 0..<feats.rows {
            var sum: Float = 0
            feats.values.withUnsafeBufferPointer { p in
                vDSP_sve(p.baseAddress! + i * feats.cols, 1, &sum, vDSP_Length(feats.cols))
            }
            energy[i] = sum
        }
        let sorted = energy.sorted()
        let low = percentile(sorted, 10)
        let high = percentile(sorted, 95)
        let gate = low + (high - low) * thresholdFraction
        var mask = energy.map { $0 > gate }
        let minSpeechFrames = Int(minSpeech * KaldiFBank.framesPerSecond)
        let minSilenceFrames = Int(minSilence * KaldiFBank.framesPerSecond)
        for (value, a, b) in runs(mask) where value == false && (b - a) < minSilenceFrames {
            for i in a..<b { mask[i] = true }
        }
        for (value, a, b) in runs(mask) where value == true && (b - a) < minSpeechFrames {
            for i in a..<b { mask[i] = false }
        }
        return mask
    }

    /// `numpy.percentile`'s linear interpolation, on an already-sorted array.
    static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let pos = (p / 100.0) * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        let frac = Float(pos - Double(lo))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    static func runs(_ mask: [Bool]) -> [(Bool, Int, Int)] {
        var out: [(Bool, Int, Int)] = []
        var i = 0
        while i < mask.count {
            var j = i
            while j < mask.count, mask[j] == mask[i] { j += 1 }
            out.append((mask[i], i, j))
            i = j
        }
        return out
    }

    static func speechRegions(_ mask: [Bool]) -> [Window] {
        runs(mask).filter { $0.0 }.map {
            Window(start: Double($0.1) / KaldiFBank.framesPerSecond,
                   end: Double($0.2) / KaldiFBank.framesPerSecond)
        }
    }

    static func windows(in regions: [Window], hop: Double = baseHopSeconds,
                        length: Double = windowSeconds) -> [Window] {
        var out: [Window] = []
        for r in regions {
            let span = r.end - r.start
            if span < minWindowSeconds { continue }
            if span <= length { out.append(r); continue }
            var t = r.start
            while t + length <= r.end + 1e-6 {
                out.append(Window(start: t, end: t + length))
                t += hop
            }
            if let last = out.last, r.end - last.end > hop * 0.5 {
                out.append(Window(start: max(r.start, r.end - length), end: r.end))
            }
        }
        return out
    }

    /// The model's input for one window: `windowFrames × 80`, tiled up if the window is
    /// short, then mean-normalised per Mel bin (the cepstral-mean step the model trained with).
    static func window(_ feats: KaldiFBank.Matrix, from w: Window) -> [Float] {
        let cols = feats.cols, need = SpeakerEmbedder.windowFrames
        let first = max(0, Int((w.start * KaldiFBank.framesPerSecond).rounded()))
        let last = min(feats.rows, Int((w.end * KaldiFBank.framesPerSecond).rounded()))
        let available = max(1, last - first)
        var out = [Float](repeating: 0, count: need * cols)
        for row in 0..<need {
            let src = min(feats.rows - 1, first + (row % available))
            for c in 0..<cols { out[row * cols + c] = feats[src, c] }
        }
        for c in 0..<cols {
            var mean: Float = 0
            out.withUnsafeBufferPointer { p in
                vDSP_meanv(p.baseAddress! + c, vDSP_Stride(cols), &mean, vDSP_Length(need))
            }
            for row in 0..<need { out[row * cols + c] -= mean }
        }
        return out
    }

    // MARK: - Clustering

    /// Average-linkage agglomerative clustering on cosine distance, cut at `threshold`.
    /// The speaker count falls out of where the merging stops. Embeddings must be
    /// L2-normalised, so cosine distance is `1 - dot`.
    static func clusterLabels(_ embeddings: [[Float]], threshold: Float) -> [Int] {
        let n = embeddings.count
        guard n > 1 else { return n == 1 ? [0] : [] }
        if n > maxClusteringWindows {
            return clusterBySubsample(embeddings, threshold: threshold)
        }

        var d = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                var dot: Float = 0
                vDSP_dotpr(embeddings[i], 1, embeddings[j], 1, &dot, vDSP_Length(SpeakerEmbedder.dimensions))
                let dist = 1 - dot
                d[i * n + j] = dist
                d[j * n + i] = dist
            }
        }
        var alive = [Bool](repeating: true, count: n)
        var size = [Float](repeating: 1, count: n)
        var members: [[Int]] = (0..<n).map { [$0] }
        var nn = [Int](repeating: -1, count: n)
        var nnd = [Float](repeating: .greatestFiniteMagnitude, count: n)

        func refreshNN(_ i: Int) {
            var best = Float.greatestFiniteMagnitude, bestJ = -1
            for j in 0..<n where j != i && alive[j] {
                if d[i * n + j] < best { best = d[i * n + j]; bestJ = j }
            }
            nn[i] = bestJ
            nnd[i] = bestJ < 0 ? .greatestFiniteMagnitude : best
        }
        for i in 0..<n { refreshNN(i) }

        var clusters = n
        while clusters > 1 {
            var bi = -1, best = Float.greatestFiniteMagnitude
            for i in 0..<n where alive[i] && nnd[i] < best { best = nnd[i]; bi = i }
            guard bi >= 0, best <= threshold else { break }
            let bj = nn[bi]
            // Lance-Williams update for average linkage (UPGMA).
            let wi = size[bi], wj = size[bj]
            for k in 0..<n where alive[k] && k != bi && k != bj {
                let merged = (wi * d[bi * n + k] + wj * d[bj * n + k]) / (wi + wj)
                d[bi * n + k] = merged
                d[k * n + bi] = merged
            }
            alive[bj] = false
            size[bi] = wi + wj
            members[bi] += members[bj]
            members[bj] = []
            clusters -= 1
            refreshNN(bi)
            for k in 0..<n where alive[k] && k != bi && (nn[k] == bi || nn[k] == bj) { refreshNN(k) }
        }

        var labels = [Int](repeating: 0, count: n)
        let order = (0..<n).filter { alive[$0] }.sorted { (members[$0].min() ?? 0) < (members[$1].min() ?? 0) }
        for (label, c) in order.enumerated() {
            for m in members[c] { labels[m] = label }
        }
        return labels
    }

    /// Folds one-window clusters into the nearest surviving centroid and renumbers, so a stray
    /// window doesn't show up in the UI as an extra speaker.
    static func pruneSingletons(_ labels: [Int], embeddings: [[Float]]) -> [Int] {
        let k = (labels.max() ?? -1) + 1
        guard k > 1 else { return labels }
        var counts = [Int](repeating: 0, count: k)
        for l in labels { counts[l] += 1 }
        let keep = Set((0..<k).filter { counts[$0] > 1 })
        guard !keep.isEmpty, keep.count < k else { return labels }
        let kept = keep.sorted()
        let centroids: [[Float]] = kept.map { c in
            var sum = [Float](repeating: 0, count: SpeakerEmbedder.dimensions)
            for (i, l) in labels.enumerated() where l == c {
                for d in 0..<SpeakerEmbedder.dimensions { sum[d] += embeddings[i][d] }
            }
            return SpeakerEmbedder.l2Normalised(sum)
        }
        var moved = labels
        for (i, l) in labels.enumerated() where !keep.contains(l) {
            var best = -Float.greatestFiniteMagnitude, bestC = kept[0]
            for (ci, c) in kept.enumerated() {
                var dot: Float = 0
                vDSP_dotpr(embeddings[i], 1, centroids[ci], 1, &dot, vDSP_Length(SpeakerEmbedder.dimensions))
                if dot > best { best = dot; bestC = c }
            }
            moved[i] = bestC
        }
        // Renumber to a dense 0..<n range, keeping order of first appearance.
        var map: [Int: Int] = [:]
        return moved.map { l in
            if let m = map[l] { return m }
            let m = map.count
            map[l] = m
            return m
        }
    }

    /// Very long recordings: cluster a uniform subsample, then pull everything else onto the
    /// nearest centroid. Keeps the 0.75 s window resolution without an n² distance matrix.
    private static func clusterBySubsample(_ embeddings: [[Float]], threshold: Float) -> [Int] {
        let n = embeddings.count
        let stride = Int((Double(n) / Double(maxClusteringWindows)).rounded(.up))
        let picks = Array(Swift.stride(from: 0, to: n, by: stride))
        let sub = picks.map { embeddings[$0] }
        let subLabels = clusterLabels(sub, threshold: threshold)
        let k = (subLabels.max() ?? -1) + 1
        guard k > 0 else { return [Int](repeating: 0, count: n) }
        var centroids = [[Float]](repeating: [Float](repeating: 0, count: SpeakerEmbedder.dimensions), count: k)
        for (i, label) in subLabels.enumerated() {
            for d in 0..<SpeakerEmbedder.dimensions { centroids[label][d] += sub[i][d] }
        }
        centroids = centroids.map { SpeakerEmbedder.l2Normalised($0) }
        return embeddings.map { e in
            var best = -Float.greatestFiniteMagnitude, bestK = 0
            for c in 0..<k {
                var dot: Float = 0
                vDSP_dotpr(e, 1, centroids[c], 1, &dot, vDSP_Length(SpeakerEmbedder.dimensions))
                if dot > best { best = dot; bestK = c }
            }
            return bestK
        }
    }

    // MARK: - Mapping onto the transcript

    /// Each segment takes the cluster that covers the most of its airtime. A segment the VAD
    /// found no speech in falls back to the nearest window, so no row is left blank in the
    /// middle of a labelled transcript.
    static func assign(segments: [Transcript.Segment], windows: [Window],
                       windowLabels: [Int], clusters: Int) -> [Int] {
        guard clusters > 0, !windows.isEmpty else { return segments.map { _ in -1 } }
        return segments.map { seg in
            var votes = [Double](repeating: 0, count: clusters)
            for (w, label) in zip(windows, windowLabels) {
                let overlap = min(seg.end, w.end) - max(seg.start, w.start)
                if overlap > 0 { votes[label] += overlap }
            }
            if let best = votes.indices.max(by: { votes[$0] < votes[$1] }), votes[best] > 0 { return best }
            let mid = (seg.start + seg.end) / 2
            var nearest = 0, bestGap = Double.greatestFiniteMagnitude
            for (i, w) in windows.enumerated() {
                let gap = max(w.start - mid, mid - w.end, 0)
                if gap < bestGap { bestGap = gap; nearest = i }
            }
            return windowLabels[nearest]
        }
    }

    /// "S1", "S2", … numbered by when each cluster first speaks, which is what the cloud does.
    static func speakerNames(for assigned: [Int], clusters: Int) -> [String] {
        var firstSeen: [Int: Int] = [:]
        for (i, c) in assigned.enumerated() where c >= 0 && firstSeen[c] == nil { firstSeen[c] = i }
        let order = (0..<clusters).sorted { (firstSeen[$0] ?? .max) < (firstSeen[$1] ?? .max) }
        var names = [String](repeating: "", count: clusters)
        for (i, c) in order.enumerated() { names[c] = "S\(i + 1)" }
        return names
    }
}
