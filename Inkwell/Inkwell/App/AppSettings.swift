import Foundation
import Observation

enum RecordingQuality: String, CaseIterable, Identifiable {
    case standard, high
    var id: String { rawValue }
    var label: String { self == .standard ? "Standard" : "High" }
    var bitRate: Int { self == .standard ? 64_000 : 128_000 }
    var detail: String { self == .standard ? "64 kbps · ~29 MB per hour" : "128 kbps · ~58 MB per hour" }
}

/// Where speaker detection runs. Apple ships no diarization API, so it is one or the other.
enum SpeakerEngine: String, CaseIterable, Identifiable {
    case onDevice, cloud
    var id: String { rawValue }
    var label: String { self == .onDevice ? "On this iPad" : "In the cloud" }
    var detail: String {
        switch self {
        case .onDevice: "A voiceprint model inside the app. No upload, no cost, works offline."
        case .cloud: "Re-transcribed on the server. Needs Backup and bills about $0.22 an hour of audio."
        }
    }
}

/// The handful of settings PRD §6.10 allows. Backed by UserDefaults.
@Observable final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var defaultTitle: String { didSet { d.set(defaultTitle, forKey: "defaultTitle") } }
    var includeDate: Bool { didSet { d.set(includeDate, forKey: "includeDate") } }
    var includeTime: Bool { didSet { d.set(includeTime, forKey: "includeTime") } }
    var defaultPaper: Paper { didSet { d.set(try? JSONEncoder().encode(defaultPaper), forKey: "defaultPaper") } }
    var defaultView: ViewMode { didSet { d.set(defaultView.rawValue, forKey: "defaultView") } }
    var drawWithFinger: Bool { didSet { d.set(drawWithFinger, forKey: "drawWithFinger") } }
    var recordingQuality: RecordingQuality { didSet { d.set(recordingQuality.rawValue, forKey: "recordingQuality") } }
    var liveTranscription: Bool { didSet { d.set(liveTranscription, forKey: "liveTranscription") } }
    var transcriptionLocaleID: String { didSet { d.set(transcriptionLocaleID, forKey: "transcriptionLocale") } }
    var backupURL: String { didSet { d.set(backupURL, forKey: "backupURL") } }
    var sortOrder: NoteSort { didSet { d.set(sortOrder.rawValue, forKey: "sortOrder") } }
    /// Detect speakers automatically once a recording finishes (on-device) or uploads (cloud).
    var detectSpeakers: Bool { didSet { d.set(detectSpeakers, forKey: "detectSpeakers") } }
    /// Which engine finds the speakers.
    var speakerEngine: SpeakerEngine { didSet { d.set(speakerEngine.rawValue, forKey: "speakerEngine") } }

    private init() {
        d.register(defaults: [
            "defaultTitle": "Note", "includeDate": true, "includeTime": false,
            "defaultView": ViewMode.seamless.rawValue, "drawWithFinger": false,
            "recordingQuality": RecordingQuality.standard.rawValue, "liveTranscription": true,
            "transcriptionLocale": "en-US", "backupURL": Self.defaultBackupURL, "sortOrder": NoteSort.modified.rawValue, "detectSpeakers": true,
            "speakerEngine": SpeakerEngine.onDevice.rawValue,
        ])
        defaultTitle = d.string(forKey: "defaultTitle") ?? "Note"
        includeDate = d.bool(forKey: "includeDate")
        includeTime = d.bool(forKey: "includeTime")
        if let data = d.data(forKey: "defaultPaper"), let p = try? JSONDecoder().decode(Paper.self, from: data) {
            defaultPaper = p
        } else {
            defaultPaper = Paper()
        }
        defaultView = ViewMode(rawValue: d.string(forKey: "defaultView") ?? "") ?? .seamless
        drawWithFinger = d.bool(forKey: "drawWithFinger")
        recordingQuality = RecordingQuality(rawValue: d.string(forKey: "recordingQuality") ?? "") ?? .standard
        liveTranscription = d.bool(forKey: "liveTranscription")
        transcriptionLocaleID = d.string(forKey: "transcriptionLocale") ?? "en-US"
        backupURL = d.string(forKey: "backupURL") ?? ""
        sortOrder = NoteSort(rawValue: d.string(forKey: "sortOrder") ?? "") ?? .modified
        detectSpeakers = d.bool(forKey: "detectSpeakers")
        speakerEngine = SpeakerEngine(rawValue: d.string(forKey: "speakerEngine") ?? "") ?? .onDevice
    }

    /// Pat's Neon backup Function (production branch). Not secret; the token is.
    static let defaultBackupURL = "https://br-lucky-resonance-b44aj51v-api.compute.c-6.us-east-2.aws.neon.tech"

    /// "Note Sep 24, 2026" (PRD §6.10).
    func newNoteTitle(at date: Date = Date()) -> String {
        var parts: [String] = []
        let base = defaultTitle.trimmingCharacters(in: .whitespaces)
        parts.append(base.isEmpty ? "Note" : base)
        if includeDate { parts.append(date.formatted(.dateTime.month(.abbreviated).day().year())) }
        if includeTime { parts.append(date.formatted(date: .omitted, time: .shortened)) }
        return parts.joined(separator: " ")
    }
}

enum NoteSort: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }
    var label: String {
        switch self {
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .title: "Title"
        }
    }
}
