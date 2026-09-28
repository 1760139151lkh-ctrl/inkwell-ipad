import Accelerate
import Foundation

/// A frame-by-frame log-Mel filterbank that matches Kaldi's `compute-fbank-feats`
/// (and so `torchaudio.compliance.kaldi.fbank`) bit-for-bit within float error.
///
/// The speaker-embedding network was trained on exactly these features, so the settings
/// below are not tunable: 16 kHz mono, 25 ms / 10 ms frames, Povey window, pre-emphasis
/// 0.97, per-frame DC removal, 512-point FFT, 80 Mel bins over 20 Hz–Nyquist, natural log
/// floored at FLT_EPSILON. Samples arrive in ±1.0 float and are scaled to 16-bit range,
/// which is what Kaldi (and WeSpeaker's recipe) feed in.
nonisolated final class KaldiFBank {
    static let sampleRate: Double = 16_000
    static let frameLength = 400          // 25 ms
    static let frameShift = 160           // 10 ms
    static let fftSize = 512              // next power of two above 400
    static let melBins = 80
    static let framesPerSecond = 100.0

    /// Kaldi floors the Mel energies at `numeric_limits<float>::epsilon()` before the log.
    private static let logFloor: Float = 1.1920929e-07
    private static let preemphasis: Float = 0.97
    private static let sampleScale: Float = 32_768

    private let window: [Float]            // Povey, frameLength
    private let melT: [Float]              // (fftSize/2 + 1) × melBins, row-major
    private let fftSetup: FFTSetup
    private let log2n: vDSP_Length = 9

    init() {
        window = Self.poveyWindow(Self.frameLength)
        melT = Self.melFilterBankTransposed()
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Row-major `rows × 80` matrix of log-Mel energies.
    struct Matrix {
        var rows: Int
        let cols: Int
        var values: [Float]

        subscript(row: Int, col: Int) -> Float { values[row * cols + col] }

        /// One frame as a slice.
        func frame(_ row: Int) -> ArraySlice<Float> { values[(row * cols)..<((row + 1) * cols)] }
    }

    /// `snip_edges = true`: only whole frames, so `1 + (n - 400) / 160` of them.
    static func frameCount(sampleCount n: Int) -> Int {
        n < frameLength ? 0 : 1 + (n - frameLength) / frameShift
    }

    func features(from samples: [Float]) -> Matrix {
        let m = Self.frameCount(sampleCount: samples.count)
        guard m > 0 else { return Matrix(rows: 0, cols: Self.melBins, values: []) }
        let fft = Self.fftSize, half = fft / 2, bins = half + 1

        // 1. Frame, de-mean, pre-emphasise, window, zero-pad to 512.
        var padded = [Float](repeating: 0, count: m * fft)
        samples.withUnsafeBufferPointer { src in
            padded.withUnsafeMutableBufferPointer { dst in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                for i in 0..<m {
                    let o = d + i * fft
                    let start = s + i * Self.frameShift
                    var scale = Self.sampleScale
                    vDSP_vsmul(start, 1, &scale, o, 1, vDSP_Length(Self.frameLength))
                    var mean: Float = 0
                    vDSP_meanv(o, 1, &mean, vDSP_Length(Self.frameLength))
                    var negMean = -mean
                    vDSP_vsadd(o, 1, &negMean, o, 1, vDSP_Length(Self.frameLength))
                    var j = Self.frameLength - 1
                    while j >= 1 { o[j] -= Self.preemphasis * o[j - 1]; j -= 1 }
                    o[0] -= Self.preemphasis * o[0]
                    vDSP_vmul(o, 1, window, 1, o, 1, vDSP_Length(Self.frameLength))
                }
            }
        }

        // 2. Power spectrum, 257 bins per frame.
        var power = [Float](repeating: 0, count: m * bins)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        padded.withUnsafeMutableBufferPointer { pad in
            power.withUnsafeMutableBufferPointer { pw in
                realp.withUnsafeMutableBufferPointer { re in
                    imagp.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        for i in 0..<m {
                            let frame = pad.baseAddress! + i * fft
                            frame.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                                vDSP_ctoz(c, 2, &split, 1, vDSP_Length(half))
                            }
                            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                            // zrip packs Re(X[0]) in realp[0] and Re(X[N/2]) in imagp[0],
                            // and scales everything by 2 — hence the 0.25 on the powers.
                            let out = pw.baseAddress! + i * bins
                            vDSP_zvmags(&split, 1, out, 1, vDSP_Length(half))
                            out[0] = re[0] * re[0]
                            out[half] = im[0] * im[0]
                            var quarter: Float = 0.25
                            vDSP_vsmul(out, 1, &quarter, out, 1, vDSP_Length(bins))
                        }
                    }
                }
            }
        }

        // 3. Mel projection, then log with Kaldi's floor.
        var mel = [Float](repeating: 0, count: m * Self.melBins)
        vDSP_mmul(power, 1, melT, 1, &mel, 1, vDSP_Length(m), vDSP_Length(Self.melBins), vDSP_Length(bins))
        var floorValue = Self.logFloor
        vDSP_vthr(mel, 1, &floorValue, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlogf(&mel, mel, &count)
        return Matrix(rows: m, cols: Self.melBins, values: mel)
    }

    // MARK: - Tables

    /// Hann (symmetric) raised to 0.85 — Kaldi's "povey" window.
    private static func poveyWindow(_ n: Int) -> [Float] {
        (0..<n).map { i in
            let hann = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(n - 1))
            return Float(pow(hann, 0.85))
        }
    }

    private static func mel(_ hz: Double) -> Double { 1127.0 * log(1.0 + hz / 700.0) }

    /// Triangular Mel bank, returned transposed (`bins × melBins`) so `vDSP_mmul` can
    /// multiply the `frames × bins` power matrix straight through it.
    private static func melFilterBankTransposed() -> [Float] {
        let fftBins = fftSize / 2                      // Kaldi builds the bank over 256 bins…
        let bins = fftBins + 1                         // …then pads one zero column for Nyquist.
        let binWidth = sampleRate / Double(fftSize)
        let lowFreq = 20.0, highFreq = sampleRate / 2
        let melLow = mel(lowFreq), melHigh = mel(highFreq)
        let delta = (melHigh - melLow) / Double(melBins + 1)
        var t = [Float](repeating: 0, count: bins * melBins)
        for b in 0..<melBins {
            let left = melLow + Double(b) * delta
            let center = left + delta
            let right = left + 2 * delta
            for f in 0..<fftBins {
                let m = mel(binWidth * Double(f))
                let up = (m - left) / (center - left)
                let down = (right - m) / (right - center)
                let w = max(0.0, min(up, down))
                if w > 0 { t[f * melBins + b] = Float(w) }
            }
        }
        return t
    }
}
