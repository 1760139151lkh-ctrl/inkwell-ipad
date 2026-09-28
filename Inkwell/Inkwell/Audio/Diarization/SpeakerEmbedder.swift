import CoreML
import Foundation

/// The bundled speaker-embedding network: 200 frames of mean-normalised 80-bin log-Mel
/// filterbank in, one 256-dimensional voiceprint out. Two windows of the same person's
/// speech land close together in cosine distance; two different people land far apart.
///
/// Model: WeSpeaker `voxceleb_resnet34_LM` (ResNet-34 + temporal stats pooling, 6.6 M
/// parameters), converted to Core ML float16. See `tools/diarization/README.md` for the
/// provenance, the licence, and the conversion script.
nonisolated final class SpeakerEmbedder {
    static let windowFrames = 200          // 2.00 s at 10 ms/frame
    static let dimensions = 256
    static let resourceName = "SpeakerEmbedding"

    enum Failure: LocalizedError {
        case modelMissing
        case badOutput

        var errorDescription: String? {
            switch self {
            case .modelMissing: "The on-device speaker model is missing from this build."
            case .badOutput: "The on-device speaker model returned an unexpected result."
            }
        }
    }

    private let model: MLModel
    private let inputName: String
    private let outputName: String

    /// True when the compiled model is present in the bundle.
    static var isBundled: Bool { modelURL != nil }

    private static var modelURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "mlpackage")
    }

    init(computeUnits: MLComputeUnits = .all) throws {
        guard let url = Self.modelURL else { throw Failure.modelMissing }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        // A .mlpackage needs compiling first; a .mlmodelc (what Xcode ships) is ready to load.
        let loadURL = url.pathExtension == "mlpackage" ? try MLModel.compileModel(at: url) : url
        model = try MLModel(contentsOf: loadURL, configuration: config)
        inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "fbank"
        outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "embedding"
    }

    /// Embeds a batch of windows. Each window is `windowFrames × 80` row-major and must
    /// already be mean-normalised. Returns L2-normalised embeddings, one row per window.
    func embed(windows: [[Float]]) throws -> [[Float]] {
        guard !windows.isEmpty else { return [] }
        let providers: [MLFeatureProvider] = try windows.map { w in
            let array = try MLMultiArray(shape: [1, NSNumber(value: Self.windowFrames), 80], dataType: .float32)
            let dst = array.dataPointer.bindMemory(to: Float.self, capacity: w.count)
            w.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: w.count) }
            return try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        }
        let results = try model.predictions(from: MLArrayBatchProvider(array: providers), options: MLPredictionOptions())
        var out: [[Float]] = []
        out.reserveCapacity(results.count)
        for i in 0..<results.count {
            guard let array = results.features(at: i).featureValue(for: outputName)?.multiArrayValue else {
                throw Failure.badOutput
            }
            var v = [Float](repeating: 0, count: Self.dimensions)
            let src = array.dataPointer.bindMemory(to: Float.self, capacity: Self.dimensions)
            for d in 0..<Self.dimensions { v[d] = src[d] }
            out.append(Self.l2Normalised(v))
        }
        return out
    }

    static func l2Normalised(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard n > 0 else { return v }
        return v.map { $0 / n }
    }
}
