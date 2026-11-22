import Foundation
import Observation
import PaperReaderKit

@MainActor @Observable
final class PDFDocumentTranslationStatus {
    enum Phase: Equatable {
        case running, paused, needsConfiguration
        case failed(String)
        case completed
    }

    fileprivate(set) var phase = Phase.paused
    fileprivate(set) var progress: PDFDocumentTranslationProgress

    fileprivate let queue: PDFDocumentTranslationQueue
    @ObservationIgnored fileprivate var preferredPage: Int
    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored fileprivate var runID = UUID()
    @ObservationIgnored fileprivate var resumeOnActivation = false

    fileprivate init(_ queue: PDFDocumentTranslationQueue, pageCount: Int, preferredPage: Int) {
        self.queue = queue
        self.progress = PDFDocumentTranslationProgress(pageCount: pageCount)
        self.preferredPage = preferredPage
    }
}

/// Jobs belong to the library session. Closing a reading view only detaches its page presentation.
@MainActor @Observable
final class PDFDocumentTranslationController {
    private var jobs: [UUID: PDFDocumentTranslationStatus] = [:]
    @ObservationIgnored private var suspended = false

    func status(for paperID: UUID) -> PDFDocumentTranslationStatus? { jobs[paperID] }

    func start(_ model: ReaderModel, paper: Paper, page: Int, resuming: Bool = false) {
        let job: PDFDocumentTranslationStatus
        if let existing = jobs[paper.id] {
            prioritize(paper.id, page: page)
            guard resuming else { return }
            switch existing.phase {
            case .running: return
            case .completed where existing.progress.partialPages == 0: return
            default: break
            }
            job = existing
        } else {
            job = makeJob(model, paper: paper, page: page)
            jobs[paper.id] = job
        }
        if model.pdfTranslationSettings.model.isEmpty {
            job.phase = .needsConfiguration
        } else if suspended {
            job.resumeOnActivation = true
        } else {
            run(job, paperID: paper.id, session: model.pdfBilingual)
        }
    }

    func prioritize(_ paperID: UUID, page: Int) {
        guard let job = jobs[paperID], job.preferredPage != page else { return }
        job.preferredPage = page
        guard job.phase == .running else { return }
        Task { await job.queue.prioritize(job.preferredPage) }
    }

    func pause(_ paperID: UUID) {
        guard let job = jobs[paperID] else { return }
        job.resumeOnActivation = false
        guard job.phase == .running else { return }
        job.runID = UUID()
        job.task?.cancel()
        job.phase = .paused
    }

    func suspend() {
        suspended = true
        for (id, job) in jobs where job.phase == .running {
            pause(id)
            job.resumeOnActivation = true
        }
    }

    func activate(session: PDFBilingualSession) {
        guard suspended else { return }
        suspended = false
        for (id, job) in jobs where job.resumeOnActivation {
            run(job, paperID: id, session: session)
        }
    }

    func settingsChanged(_ model: ReaderModel, previousSettings: ModelSettings, resumeVisible: Bool) {
        let settings = model.pdfTranslationSettings
        let connectionChanged =
            previousSettings.model != settings.model || previousSettings.baseURL != settings.baseURL
            || previousSettings.credentialID != settings.credentialID
        for (id, previous) in jobs {
            let wasPaused = previous.phase == .paused && !previous.resumeOnActivation
            pause(id)
            guard let paper = model.state.papers.first(where: { $0.id == id }) else {
                jobs[id] = nil
                continue
            }
            // Bind future requests to the new endpoint and credential. Other papers wait for an explicit resume.
            jobs[id] = makeJob(model, paper: paper, page: previous.preferredPage)
            if case .failed = previous.phase, !connectionChanged {
                jobs[id]?.phase = previous.phase
                continue
            }
            if resumeVisible, !wasPaused, model.pdfBilingual.matches(model), model.selectedPaperID == id {
                start(model, paper: paper, page: model.visiblePage, resuming: true)
            }
        }
    }

    private func makeJob(_ model: ReaderModel, paper: Paper, page: Int) -> PDFDocumentTranslationStatus {
        let settings = model.pdfTranslationSettings
        let validation = model.pdfValidation
        let configuration = model.configurationStore
        let queue = PDFDocumentTranslationQueue(
            url: model.root.appendingPathComponent(paper.originalPath), documentHash: paper.digest,
            pageCount: paper.pageCount, store: model.pdfTranslations, settings: settings, client: model.client,
            key: {
                if let key = validation?.key { return key }
                return try await configuration.keyForRequest(settings)
            })
        return PDFDocumentTranslationStatus(queue, pageCount: paper.pageCount, preferredPage: page)
    }

    private func run(_ job: PDFDocumentTranslationStatus, paperID: UUID, session: PDFBilingualSession) {
        let token = UUID()
        let previous = job.task
        job.runID = token
        job.resumeOnActivation = false
        job.phase = .running
        let progress: @MainActor @Sendable (PDFDocumentTranslationProgress) -> Void = { value in
            if job.runID == token { job.progress = value }
        }
        let publish: @MainActor @Sendable (Int, [String: String]) -> Void = { [weak session] page, values in
            if job.runID == token { session?.receiveDocumentTranslations(values, paperID: paperID, page: page) }
        }
        job.task = Task {
            // Cancellation may still be unwinding the request. Reuse the same serial queue after it releases the page.
            await previous?.value
            guard job.runID == token, !Task.isCancelled else { return }
            defer { if job.runID == token { job.task = nil } }
            do {
                try await job.queue.run(
                    prioritizing: job.preferredPage, onProgress: { await progress($0) },
                    onUpdate: { await publish($0, $1) })
                if job.runID == token { job.phase = .completed }
            } catch {
                if job.runID == token { job.phase = .failed(error.localizedDescription) }
            }
        }
    }
}
