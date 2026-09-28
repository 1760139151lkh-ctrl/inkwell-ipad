import Foundation
import Observation
import PencilKit
import SwiftData
import UIKit

enum SideRail: Equatable { case none, recordings, pages }

/// Per-open-note state. Owns the canvas controller and the playback controller.
@MainActor @Observable final class EditorModel {
    let note: Note
    let canvas: CanvasController
    let playback = PlaybackController()
    let context: ModelContext
    let tools = ToolState.shared

    var subBarVisible = true
    /// Set when the user taps a tool WHILE recording. The recording bar and the tool sub-bar share
    /// one slot, and recording used to win outright, which made pen colour and width unreachable
    /// during the exact thing this app is for: writing while the mic is on.
    var toolBarBeatsRecording = false
    var visiblePage = 0
    var pageCount: Int
    var canUndo = false
    var canRedo = false
    var rail: SideRail = .none
    var isEmpty: Bool
    var showPaperSheet = false
    var showHandoff = false
    var showGoToPage = false
    /// Recording selected in the recordings panel.
    var selectedRecordingID: UUID?
    /// Recording the playhead was last inside (so selection only follows real crossings).
    var lastPlayingRecordingID: UUID?
    /// Transcript segment to scroll to when the panel opens (from search).
    var focusSegmentStart: Double?
    /// Transcripts of saved recordings, keyed by recording id.
    var transcripts: [UUID: Transcript] = [:]
    var transcribing: [UUID: Double] = [:]

    /// Text box / image selected on the page.
    var selectedElementID: UUID?
    var showPhotoPicker = false
    var showPDFImporter = false
    /// Decoded element images, by element id.
    var imageCache: [UUID: UIImage] = [:]

    private(set) var strokeIndex = StrokeTimeIndex()
    private var saveTask: Task<Void, Never>?
    private var autoScrollSuspendedUntil = Date.distantPast
    private var isPenDown = false
    /// Ink changed since the last flush (modifiedAt is stamped on save, not per stroke).
    private var inkDirty = false
    /// Stroke bounds, index-aligned with the drawing (auto-scroll without re-reading strokes).
    private var strokeBounds: [CGRect] = []

    init(note: Note, context: ModelContext) {
        self.note = note
        self.context = context
        let drawing = DrawingStore.load(note.id)
        self.pageCount = max(1, note.pageCount)
        let pdfURL = note.pdfBackgroundFile.map { NoteFiles.folder(note.id).appendingPathComponent($0) }
        self.isEmpty = drawing.strokes.isEmpty && note.elements.isEmpty && pdfURL == nil
        self.canvas = CanvasController(drawing: drawing, paper: note.paper, pageCount: note.pageCount, title: note.title,
                                       viewMode: note.viewMode ?? AppSettings.shared.defaultView, pdfURL: pdfURL)
        wire()
        wireElements()
        sweepOrphanImages()
        refreshElements()
        observeAudioFiles()
        applyTool()
        canvas.resetUndo()
        Task { await reloadAudio() }
    }

    private func wire() {
        canvas.onDrawingChanged = { [weak self] drawing in self?.drawingChanged(drawing) }
        canvas.onVisiblePageChanged = { [weak self] page in self?.visiblePage = page }
        canvas.onUndoStateChanged = { [weak self] u, r in
            self?.canUndo = u
            self?.canRedo = r
        }
        canvas.onTitleCommitted = { [weak self] title in self?.rename(title) }
        canvas.onTap = { [weak self] point, isPencil in self?.handleTap(point, isPencil: isPencil) }
        canvas.onPencilDoubleTap = { [weak self] in
            self?.tools.toggleEraser()
            self?.applyTool()
        }
        canvas.onUserScrolled = { [weak self] in self?.autoScrollSuspendedUntil = Date().addingTimeInterval(5) }
        canvas.onToolUseChanged = { [weak self] down in self?.isPenDown = down }
        playback.onTick = { [weak self] t in self?.playheadMoved(t) }
    }

    // MARK: - Tools

    func select(_ tool: ToolKind) {
        if tool != tools.current { deselectElement() }
        if tools.current == tool {
            if tool.hasSubBar { subBarVisible.toggle() }
        } else {
            tools.select(tool)
            subBarVisible = tool.hasSubBar
        }
        // Tapping a tool is an explicit request for its sub-bar, so let it take the slot back from
        // the recording bar. Closing the sub-bar hands the slot straight back.
        toolBarBeatsRecording = subBarVisible && tool.hasSubBar
        applyTool()
    }

    func applyTool() {
        canvas.setTool(tools.pkTool)
    }

    // MARK: - Drawing

    private func drawingChanged(_ drawing: PKDrawing) {
        updateIsEmpty(strokes: drawing.strokes.count)
        rebuildStrokeIndex(drawing)
        autoAppendPages(drawing)
        inkDirty = true
        scheduleSave()
    }

    /// Adds a page when a stroke ends in the bottom 20% of the last page (PRD §8.2).
    private func autoAppendPages(_ drawing: PKDrawing) {
        let geo = PageGeometry(paper: note.paper)
        var needed = pageCount
        if let last = drawing.strokes.last {
            let lastPage = geo.pageRect(pageCount - 1)
            let threshold = lastPage.maxY - lastPage.height * 0.2
            if last.renderBounds.maxY > threshold && last.renderBounds.minY < lastPage.maxY + PageGeometry.gap {
                needed = pageCount + 1
            }
        }
        let maxY = drawing.bounds.isNull ? 0 : drawing.bounds.maxY
        needed = max(needed, geo.pagesNeeded(forMaxY: maxY))
        if needed != pageCount { setPageCount(needed) }
    }

    func setPageCount(_ n: Int) {
        pageCount = max(1, n)
        note.pageCount = pageCount
        canvas.setPageCount(pageCount)
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes the drawing now (debounced path, background, leaving the note). The drawing
    /// is written synchronously for crash safety; the thumbnail renders off the main thread.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        let drawing = canvas.drawing
        DrawingStore.save(drawing, noteID: note.id)
        if inkDirty {
            note.modifiedAt = Date()
            inkDirty = false
        }
        try? context.save()
        BackupEngine.shared.noteChanged()
        let noteID = note.id, paper = note.paper, elements = elementSnapshots
        let pdfURL = note.pdfBackgroundFile.map { NoteFiles.folder(noteID).appendingPathComponent($0) }
        let render = Task.detached(priority: .utility) {
            let pdf = pdfURL.flatMap { CGPDFDocument($0 as CFURL) }
            ThumbnailRenderer.render(drawing: drawing, paper: paper, noteID: noteID, pdf: pdf, elements: elements)
        }
        Task { [weak self] in
            await render.value
            guard let self else { return }
            self.note.thumbnailVersion += 1
            try? self.context.save()
        }
    }

    // MARK: - Note operations

    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.title = trimmed.isEmpty ? AppSettings.shared.newNoteTitle(at: note.createdAt) : trimmed
        canvas.setTitle(note.title)
        note.modifiedAt = Date()
        try? context.save()
    }

    func applyPaper(_ paper: Paper) {
        note.paper = paper
        canvas.setPaper(paper)
        note.modifiedAt = Date()
        flush()
    }

    func applyPaperStyle(_ style: PaperStyle) {
        var p = note.paper
        p.style = style
        applyPaper(p)
    }

    var currentViewMode: ViewMode { note.viewMode ?? AppSettings.shared.defaultView }

    func setViewMode(_ mode: ViewMode) {
        note.viewMode = mode
        canvas.setViewMode(mode)
        note.modifiedAt = Date()
        try? context.save()
        BackupEngine.shared.noteChanged()
    }

    func goToPage(_ index: Int) { canvas.scrollToPage(index) }
    func pageUp() { canvas.scrollToPage(max(0, visiblePage - 1)) }
    func pageDown() { canvas.scrollToPage(min(pageCount - 1, visiblePage + 1)) }

    func undo() { canvas.undo() }
    func redo() { canvas.redo() }

    // MARK: - Audio

    var recorder: AudioRecorder { .shared }
    var isRecordingHere: Bool { recorder.isRecording && recorder.noteID == note.id }

    func toggleRecording() {
        Task {
            if isRecordingHere {
                await recorder.stop()   // AppModel's onRecordingFinished reloads the timeline
            } else {
                if recorder.isRecording { await recorder.stop() }
                playback.disengage()
                await recorder.start(note: note, context: context)
                selectedRecordingID = recorder.recordingID
                rebuildStrokeIndex(canvas.drawing)
            }
        }
    }

    func reloadAudio() async {
        await playback.load(noteID: note.id, recordings: note.recordings)
        for rec in note.recordings where rec.duration > 0 {
            if let t = TranscriptStore.load(noteID: note.id, recordingID: rec.id) { transcripts[rec.id] = t }
        }
        if selectedRecordingID == nil || !note.recordings.contains(where: { $0.id == selectedRecordingID }) {
            selectedRecordingID = note.orderedRecordings.last(where: { $0.duration > 0 })?.id
        }
        rebuildStrokeIndex(canvas.drawing)
    }

    private func rebuildStrokeIndex(_ drawing: PKDrawing) {
        strokeIndex = StrokeTimeIndex(drawing: drawing, timeline: playback.timeline)
        strokeBounds = drawing.strokes.map(\.renderBounds)
        canvas.invalidateReplay()
        refreshReplay()
    }

    /// Reload when a recording's .m4a or final transcript lands after Stop.
    private func observeAudioFiles() {
        let nc = NotificationCenter.default
        let id = note.id
        for name in [Notification.Name.inkwellAudioTranscoded, .inkwellTranscriptFinished] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard (n.object as? UUID) == id else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.reloadAudio() }
                }
            }
        }
    }

    func togglePlayback() {
        if playback.isPlaying { playback.pause() } else { playback.play() }
        subBarVisible = true
    }

    private func playheadMoved(_ t: TimeInterval) {
        refreshReplay()
        autoScroll(t)
    }

    func refreshReplay() {
        let active = playback.isEngaged && !isRecordingHere
        canvas.updateReplay(active: active, playhead: playback.currentTime, index: strokeIndex)
        if active {
            let t = playback.currentTime
            let future = Set(note.elements.compactMap { e -> UUID? in
                guard let et = playback.timeline.timelineTime(of: e.createdAt) else { return nil }
                return et > t ? e.id : nil
            })
            canvas.setElementReplay(future: future)
        }
    }

    /// Auto-scroll (PRD §7.4): keep the stroke being "written" on screen,
    /// except for 5 s after any user scroll.
    private func autoScroll(_ t: TimeInterval) {
        guard playback.isPlaying, Date() > autoScrollSuspendedUntil, !isPenDown,
              let i = strokeIndex.latestStroke(atOrBefore: t), i < strokeBounds.count else { return }
        canvas.ensureVisible(strokeBounds[i])
    }

    /// Tap-to-seek (PRD §7.4): Navigate mode (finger or pencil), or a finger tap while replay is on.
    private func handleTap(_ point: CGPoint, isPencil: Bool) {
        if handleElementTap(point) { return }
        let seekAllowed = tools.current == .navigate || (!isPencil && playback.isEngaged)
        guard seekAllowed, !isRecordingHere else { return }
        let strokes = canvas.drawing.strokes
        guard let hit = StrokeHitTester.hit(point: point, strokes: strokes),
              let t = strokeIndex.times[safe: hit] ?? nil else { return }
        playback.jump(to: t)
        subBarVisible = true
    }

    /// Transcript line tapped: jump exactly to the start of that line (no pre-roll, so the
    /// tapped line is the one highlighted and heard) and always play.
    func seek(recordingID: UUID, local: TimeInterval) {
        guard let offset = playback.timeline.offset(of: recordingID) else { return }
        selectedRecordingID = recordingID
        playback.jump(to: offset + local, preRoll: 0)
    }

    // MARK: Speakers

    /// "Kunal", or "Speaker 2" until named.
    func speakerName(recordingID: UUID, label: String) -> String {
        // Per-recording name first (labels restart in each recording), then a note-wide one.
        note.speakerNames["\(recordingID.lowercased):\(label)"] ?? note.speakerNames[label]
            ?? "Speaker \(label.drop(while: { !$0.isNumber }))"
    }

    func renameSpeaker(recordingID: UUID, label: String, to name: String) {
        var names = note.speakerNames
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))   // server limit
        names["\(recordingID.lowercased):\(label)"] = trimmed.isEmpty ? nil : trimmed
        note.speakerNames = names
        SpeakerDirectory.remember(trimmed)
        note.modifiedAt = Date()
        try? context.save()
        BackupEngine.shared.noteChanged()
    }

    func identifySpeakers(_ rec: Recording) {
        SpeakerDetection.shared.start(noteID: note.id, recordingID: rec.id)
    }

    /// Tap on a recording row: select it; if audio is playing, jump to its start and keep playing.
    func selectRecording(_ id: UUID) {
        selectedRecordingID = id
        guard playback.isPlaying, let seg = playback.timeline.segments.first(where: { $0.recordingID == id }) else { return }
        let t = playback.currentTime
        if t < seg.offset || t >= seg.offset + seg.duration {
            lastPlayingRecordingID = id
            playback.seek(to: seg.offset)
        }
    }

    /// Big play button in the Recordings panel: plays the selected recording. If the playhead
    /// isn't inside it (e.g. you picked Recording 3 while at 0:00), start at its beginning.
    func playSelectedRecording() {
        if playback.isPlaying { playback.pause(); return }
        if let id = selectedRecordingID, let seg = playback.timeline.segments.first(where: { $0.recordingID == id }) {
            let t = playback.currentTime
            if t < seg.offset || t >= seg.offset + seg.duration - 0.05 { playback.seek(to: seg.offset) }
        }
        playback.play()
        subBarVisible = true
    }

    func renameRecording(_ rec: Recording, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        rec.name = trimmed.isEmpty ? "Recording \(rec.order + 1)" : trimmed
        note.modifiedAt = Date()
        try? context.save()
        BackupEngine.shared.noteChanged()
    }

    func deleteRecording(_ rec: Recording) {
        NoteFiles.deleteRecordingFiles(noteID: note.id, recordingID: rec.id)
        note.recordings.removeAll { $0.id == rec.id }
        context.delete(rec)
        // Keep timeline order contiguous.
        for (i, r) in note.orderedRecordings.enumerated() { r.order = i }
        note.modifiedAt = Date()
        try? context.save()
        transcripts[rec.id] = nil
        if selectedRecordingID == rec.id { selectedRecordingID = nil }
        playback.teardown()
        Task { await reloadAudio() }
    }

    /// Backfill "Transcribe" (PRD §7.6).
    func transcribe(_ rec: Recording) {
        guard transcribing[rec.id] == nil,
              let url = NoteFiles.playableAudioURL(noteID: note.id, recordingID: rec.id) else { return }
        transcribing[rec.id] = 0
        let noteID = note.id, recID = rec.id
        let locale = Locale(identifier: AppSettings.shared.transcriptionLocaleID)
        Task {
            do {
                let t = try await LiveTranscriber.transcribeFile(url: url, noteID: noteID, recordingID: recID, locale: locale) { p in
                    Task { @MainActor in self.transcribing[recID] = p }
                }
                // If speaker detection landed meanwhile, keep its (better, labelled) transcript.
                let current = TranscriptStore.load(noteID: noteID, recordingID: recID)
                let detecting = SpeakerDetection.shared.status[recID] == .running
                if current?.speakers.isEmpty ?? true, !detecting {
                    TranscriptStore.save(t, noteID: noteID)
                    transcripts[recID] = t
                    rec.transcriptText = t.fullText
                    rec.transcriptStatus = .complete
                    note.modifiedAt = Date()   // new transcript → back it up
                    BackupEngine.shared.noteChanged()
                }
            } catch {
                rec.transcriptStatus = .failed
            }
            transcribing[recID] = nil
            try? context.save()
        }
    }

    func close() {
        deselectElement()
        canvas.resetUndo()   // undo actions target this note; never let them outlive it
        flush()
        playback.teardown()
    }
}

extension Array {
    nonisolated subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
