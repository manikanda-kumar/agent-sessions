import Foundation
import Combine
import SwiftUI

final class AntigravitySessionIndexer: ObservableObject, SessionIndexerProtocol, @unchecked Sendable {
    @Published private(set) var allSessions: [Session] = []
    @Published private(set) var sessions: [Session] = []
    @Published var isIndexing: Bool = false
    @Published var isProcessingTranscripts: Bool = false
    @Published var progressText: String = ""
    @Published var filesProcessed: Int = 0
    @Published var totalFiles: Int = 0
    @Published var indexingError: String? = nil
    @Published var hasEmptyDirectory: Bool = false
    @Published var launchPhase: LaunchPhase = .idle
    @Published var query: String = ""
    @Published var queryDraft: String = ""
    @Published var dateFrom: Date? = nil
    @Published var dateTo: Date? = nil
    @Published var selectedModel: String? = nil
    @Published var selectedKinds: Set<SessionEventKind> = Set(SessionEventKind.allCases)
    @Published var projectFilter: String? = nil
    @Published var isLoadingSession: Bool = false
    @Published var loadingSessionID: String? = nil
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    private let transcriptCache = TranscriptCache()
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    @AppStorage(PreferencesKey.Paths.antigravitySessionsRootOverride) var sessionsRootOverride: String = ""
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref: Bool = true { didSet { recomputeNow() } }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref: Bool = true { didSet { recomputeNow() } }

    private var discovery: AntigravitySessionDiscovery
    private var lastOverride: String = ""
    private var refreshToken = UUID()
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSLock()
    private var cancellables = Set<AnyCancellable>()

    init() {
        let initialOverride = UserDefaults.standard.string(forKey: PreferencesKey.Paths.antigravitySessionsRootOverride) ?? ""
        self.discovery = AntigravitySessionDiscovery(customRoot: initialOverride.isEmpty ? nil : initialOverride)
        self.lastOverride = initialOverride

        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: OptionalDateEquality.eq),
            $dateTo.removeDuplicates(by: OptionalDateEquality.eq),
            $selectedModel.removeDuplicates()
        )

        Publishers.CombineLatest3(inputs, $selectedKinds.removeDuplicates(), $allSessions)
            .receive(on: FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] input, kinds, all -> [Session] in
                let (q, from, to, model) = input
                let filters = Filters(query: q,
                                      dateFrom: from,
                                      dateTo: to,
                                      model: model,
                                      kinds: kinds,
                                      repoName: self?.projectFilter,
                                      pathContains: nil)
                var results = FilterEngine.filterSessions(all, filters: filters, transcriptCache: self?.transcriptCache, allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
                if self?.hideZeroMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 0 } }
                if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
                return results
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)
    }

    var canAccessRootDirectory: Bool {
        if FileManager.default.fileExists(atPath: discovery.historyFileURL().path) {
            return true
        }
        return discovery.hasConversationDBFiles()
    }

    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        if !AgentEnablement.isEnabled(.antigravity) { return }

        let currentOverride = UserDefaults.standard.string(forKey: PreferencesKey.Paths.antigravitySessionsRootOverride) ?? ""
        if currentOverride != lastOverride {
            discovery = AntigravitySessionDiscovery(customRoot: currentOverride.isEmpty ? nil : currentOverride)
            lastOverride = currentOverride
        }

        let token = UUID()
        refreshToken = token
        launchPhase = .hydrating
        isIndexing = true
        isProcessingTranscripts = false
        progressText = "Scanning…"
        filesProcessed = 0
        totalFiles = 0
        indexingError = nil
        hasEmptyDirectory = false

        let requestedPriority: TaskPriority = executionProfile.deferNonCriticalWork ? .utility : .userInitiated
        let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : requestedPriority
        Task.detached(priority: prio) { [weak self, token] in
            guard let self else { return }
            let historyURL = self.discovery.historyFileURL()
            let parsed = AntigravitySessionParser.parseHistoryFile(at: historyURL)
            let merged = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: parsed, source: .antigravity)
            await MainActor.run {
                guard self.refreshToken == token else { return }
                self.allSessions = merged
                self.isIndexing = false
                self.totalFiles = merged.isEmpty ? 0 : 1
                self.filesProcessed = self.totalFiles
                self.hasEmptyDirectory = merged.isEmpty
                self.progressText = "Ready"
                self.launchPhase = .ready
            }
        }
    }

    func applySearch() {
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    func recomputeNow() {
        let filters = Filters(query: query,
                              dateFrom: dateFrom,
                              dateTo: dateTo,
                              model: selectedModel,
                              kinds: selectedKinds,
                              repoName: projectFilter,
                              pathContains: nil)
        var results = FilterEngine.filterSessions(allSessions, filters: filters, transcriptCache: transcriptCache, allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
        if hideZeroMessageSessionsPref { results = results.filter { $0.messageCount > 0 } }
        if hideLowMessageSessionsPref { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
        Task { @MainActor [weak self] in self?.sessions = results }
    }

    func updateSession(_ updated: Session) {
        if let idx = allSessions.firstIndex(where: { $0.id == updated.id }) {
            allSessions[idx] = updated
        }
        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: updated, filters: filters, mode: .normal)
        transcriptCache.set(updated.id, transcript: transcript)
    }

    enum ReloadReason: String {
        case selection
        case focusedSessionMonitor
        case manualRefresh
    }

    func reloadSession(id: String, force: Bool = false, reason: ReloadReason = .selection) {
        reloadLock.lock()
        if reloadingSessionIDs.contains(id) {
            reloadLock.unlock()
            return
        }
        reloadingSessionIDs.insert(id)
        reloadLock.unlock()

        let existingSnapshot: Session? = {
            if Thread.isMainThread {
                return self.allSessions.first(where: { $0.id == id })
            }
            var session: Session?
            DispatchQueue.main.sync {
                session = self.allSessions.first(where: { $0.id == id })
            }
            return session
        }()

        let ioQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        ioQueue.async {
            defer {
                self.reloadLock.lock()
                self.reloadingSessionIDs.remove(id)
                self.reloadLock.unlock()
            }

            guard let existing = existingSnapshot,
                  FileManager.default.fileExists(atPath: existing.filePath) else { return }
            if !existing.events.isEmpty && !force { return }

            let historyURL = URL(fileURLWithPath: existing.filePath)
            let parsed = AntigravitySessionParser.parseSessionFull(id: id, historyURL: historyURL) ?? existing

            Task { @MainActor [weak self] in
                guard let self else { return }
                if let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
                    self.allSessions[idx] = parsed
                    let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                    let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: parsed, filters: filters, mode: .normal)
                    self.transcriptCache.set(parsed.id, transcript: transcript)
                }
                self.recomputeNow()
            }
        }
    }
}