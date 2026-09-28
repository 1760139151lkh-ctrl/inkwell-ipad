import Foundation
import SwiftData
import CoreGraphics

// MARK: - Enums

nonisolated enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case blank, ruled, grid, dot
    var id: String { rawValue }
    var label: String {
        switch self {
        case .blank: "Plain"
        case .ruled: "Rule"
        case .grid: "Grid"
        case .dot: "Dot"
        }
    }
}

nonisolated enum PaperSpacing: String, Codable, CaseIterable, Identifiable {
    case narrow, medium, wide
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Line / grid pitch in page points (US Letter = 612 × 792).
    var points: CGFloat {
        switch self {
        case .narrow: 22
        case .medium: 29
        case .wide: 36
        }
    }
}

nonisolated enum PaperColor: String, Codable, CaseIterable, Identifiable {
    case white, offWhite, cream, black, blueGray, tan
    var id: String { rawValue }
    var label: String {
        switch self {
        case .white: "White"
        case .offWhite: "Off-white"
        case .cream: "Cream"
        case .black: "Black"
        case .blueGray: "Blue-gray"
        case .tan: "Tan"
        }
    }
    var hex: String {
        switch self {
        case .white: "#FFFFFF"
        case .offWhite: "#F6F5F1"
        case .cream: "#FBF3DC"
        case .black: "#1C1C1E"
        case .blueGray: "#E4EAF1"
        case .tan: "#E9DCC4"
        }
    }
    var isDark: Bool { self == .black }
    /// Pattern ink for lines / dots on this paper.
    var patternHex: String { isDark ? "#3C4048" : "#C9D3E0" }
}

nonisolated enum TranscriptStatus: String, Codable {
    case none, live, complete, failed
}

nonisolated enum ElementKind: String, Codable {
    case text, image
}

nonisolated enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case seamless, singlePage
    var id: String { rawValue }
    var label: String { self == .seamless ? "Seamless" : "Single Page" }
}

/// Everything about a note's paper, applied to the whole note (PRD §6.11).
nonisolated struct Paper: Codable, Equatable, Hashable {
    var style: PaperStyle = .blank
    var color: PaperColor = .white
    var spacing: PaperSpacing = .medium
    var landscape: Bool = false

    var pageSize: CGSize { landscape ? CGSize(width: 792, height: 612) : CGSize(width: 612, height: 792) }
}

// MARK: - Models (PRD §8.1)

@Model final class Subject {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    var sortIndex: Int
    var divider: SubjectDivider?
    @Relationship(deleteRule: .nullify, inverse: \Note.subject) var notes: [Note] = []

    init(name: String, colorHex: String, sortIndex: Int) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.sortIndex = sortIndex
    }

    var liveNotes: [Note] { notes.filter { $0.deletedAt == nil } }
}

@Model final class SubjectDivider {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortIndex: Int
    var isCollapsed: Bool

    init(name: String, sortIndex: Int) {
        self.id = UUID()
        self.name = name
        self.sortIndex = sortIndex
        self.isCollapsed = false
    }
}

@Model final class Note {
    @Attribute(.unique) var id: UUID
    var title: String
    var subject: Subject?
    var createdAt: Date
    var modifiedAt: Date
    var paperStyleRaw: String
    var paperColorRaw: String
    var paperSpacingRaw: String
    var paperLandscape: Bool
    var pageCount: Int
    var bookmarkedPages: [Int]
    var pdfBackgroundFile: String?
    @Relationship(deleteRule: .cascade, inverse: \Recording.note) var recordings: [Recording] = []
    @Relationship(deleteRule: .cascade, inverse: \PageElement.note) var elements: [PageElement] = []
    var deletedAt: Date?
    var lastBackedUpAt: Date?
    /// Bumped whenever the thumbnail file is rewritten, so list rows refresh.
    var thumbnailVersion: Int
    /// Seamless / Single Page; nil = the Settings default.
    var viewModeRaw: String?
    /// Speaker names, keyed "<lowercase recordingID>:<label>" (or a note-wide "<label>") → "Kunal".
    var speakerNamesJSON: String?

    init(title: String, subject: Subject?, paper: Paper) {
        self.id = UUID()
        self.title = title
        self.subject = subject
        let now = Date()
        self.createdAt = now
        self.modifiedAt = now
        self.paperStyleRaw = paper.style.rawValue
        self.paperColorRaw = paper.color.rawValue
        self.paperSpacingRaw = paper.spacing.rawValue
        self.paperLandscape = paper.landscape
        self.pageCount = 1
        self.bookmarkedPages = []
        self.thumbnailVersion = 0
    }

    var paper: Paper {
        get {
            Paper(style: PaperStyle(rawValue: paperStyleRaw) ?? .blank,
                  color: PaperColor(rawValue: paperColorRaw) ?? .white,
                  spacing: PaperSpacing(rawValue: paperSpacingRaw) ?? .medium,
                  landscape: paperLandscape)
        }
        set {
            paperStyleRaw = newValue.style.rawValue
            paperColorRaw = newValue.color.rawValue
            paperSpacingRaw = newValue.spacing.rawValue
            paperLandscape = newValue.landscape
        }
    }

    var speakerNames: [String: String] {
        get { speakerNamesJSON.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:] }
        set { speakerNamesJSON = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } }
    }

    /// nil = follow Settings › Document › Default view.
    var viewMode: ViewMode? {
        get { viewModeRaw.flatMap(ViewMode.init(rawValue:)) }
        set { viewModeRaw = newValue?.rawValue }
    }

    /// Recordings in timeline order.
    var orderedRecordings: [Recording] { recordings.sorted { $0.order < $1.order } }
    var hasAudio: Bool { recordings.contains { $0.duration > 0 } }
}

@Model final class Recording {
    @Attribute(.unique) var id: UUID
    var note: Note?
    var order: Int
    var name: String
    var startedAt: Date
    var duration: Double
    var fileName: String
    var transcriptStatusRaw: String
    var transcriptText: String?

    init(note: Note, order: Int, startedAt: Date) {
        let id = UUID()
        self.id = id
        self.note = note
        self.order = order
        self.name = "Recording \(order + 1)"
        self.startedAt = startedAt
        self.duration = 0
        self.fileName = "\(id.uuidString).m4a"
        self.transcriptStatusRaw = TranscriptStatus.none.rawValue
    }

    var transcriptStatus: TranscriptStatus {
        get { TranscriptStatus(rawValue: transcriptStatusRaw) ?? .none }
        set { transcriptStatusRaw = newValue.rawValue }
    }

    var endedAt: Date { startedAt.addingTimeInterval(duration) }
}

@Model final class PageElement {
    @Attribute(.unique) var id: UUID
    var note: Note?
    var kindRaw: String
    var frameX: Double
    var frameY: Double
    var frameW: Double
    var frameH: Double
    var createdAt: Date
    var text: String?
    var imageFileName: String?
    /// Text boxes: point size in page units, weight, and color.
    var fontSize: Double?
    var isBold: Bool?
    var colorHex: String?

    init(kind: ElementKind, frame: CGRect) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.frameX = frame.origin.x
        self.frameY = frame.origin.y
        self.frameW = frame.width
        self.frameH = frame.height
        self.createdAt = Date()
    }

    var kind: ElementKind { ElementKind(rawValue: kindRaw) ?? .text }
    var frame: CGRect {
        get { CGRect(x: frameX, y: frameY, width: frameW, height: frameH) }
        set { frameX = newValue.origin.x; frameY = newValue.origin.y; frameW = newValue.width; frameH = newValue.height }
    }
}
