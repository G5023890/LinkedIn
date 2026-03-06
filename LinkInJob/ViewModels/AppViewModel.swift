import AppKit
import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    private static let sortDefaultsKey = "app.sortOption"
    private static let sidebarDefaultsKey = "app.sidebarFilter"
    private static let translationMethodDefaultsKey = "app.translationMethod"
    private static let googleTranslateAPIKeyLegacyDefaultsKey = "app.googleTranslateAPIKey"
    private lazy var projectRootDirectory: String = Self.resolveProjectRootDirectory()
    private let keychainStore = KeychainStore(
        service: "com.grigorymordokhovich.LinkInJob",
        account: "google_translate_api_key"
    )

    enum SidebarFilter: Hashable {
        case stage(Stage)
        case starred
        case noReply

        var title: String {
            switch self {
            case .stage(let stage):
                return stage.title
            case .starred:
                return "Starred"
            case .noReply:
                return "No reply > 5 days"
            }
        }

        var symbol: String {
            switch self {
            case .stage(let stage):
                return stage.symbol
            case .starred:
                return "star"
            case .noReply:
                return "clock.badge.exclamationmark"
            }
        }
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case date = "Date"
        case age = "Age"
        case company = "Company"

        var id: String { rawValue }
    }

    enum TranslationMethod: String, CaseIterable, Identifiable {
        case manualOnly = "manual_only"
        case googleUnofficial = "google_unofficial"
        case googleAPI = "google_api"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .manualOnly:
                return "Только ручной перевод по запросу"
            case .googleUnofficial:
                return "Google Web (gtx)"
            case .googleAPI:
                return "Google Cloud API"
            }
        }
    }

    @Published var applications: [ApplicationItem]
    @Published var selectedStage: Stage = .inbox
    @Published var selectedItemID: ApplicationItem.ID?
    @Published var searchText: String = ""
    @Published var sidebarFilter: SidebarFilter = .stage(.inbox) {
        didSet {
            UserDefaults.standard.set(encodeSidebarFilter(sidebarFilter), forKey: Self.sidebarDefaultsKey)
        }
    }
    @Published var sortOption: SortOption = .date {
        didSet {
            UserDefaults.standard.set(sortOption.rawValue, forKey: Self.sortDefaultsKey)
        }
    }
    @Published var dataSourceLabel: String = "Mock data"
    @Published var isSyncing: Bool = false
    @Published var syncStatusText: String = ""
    @Published var translationMethod: TranslationMethod = .googleUnofficial {
        didSet {
            UserDefaults.standard.set(translationMethod.rawValue, forKey: Self.translationMethodDefaultsKey)
        }
    }
    @Published private(set) var hasGoogleTranslateAPIKey: Bool = false
    @Published private(set) var translatingDescriptionIDs: Set<UUID> = []
    private var googleTranslateAPIKey: String = ""

    init(applications: [ApplicationItem] = AppViewModel.mockApplications()) {
        self.applications = applications
        if let rawSort = UserDefaults.standard.string(forKey: Self.sortDefaultsKey),
           let savedSort = SortOption(rawValue: rawSort) {
            self.sortOption = savedSort
        }
        if let rawFilter = UserDefaults.standard.string(forKey: Self.sidebarDefaultsKey),
           let savedFilter = decodeSidebarFilter(rawFilter) {
            self.sidebarFilter = savedFilter
            if case .stage(let stage) = savedFilter {
                self.selectedStage = stage
            }
        }
        if let rawMethod = UserDefaults.standard.string(forKey: Self.translationMethodDefaultsKey),
           let savedMethod = TranslationMethod(rawValue: rawMethod) {
            self.translationMethod = savedMethod
        }
        loadGoogleTranslateAPIKeyFromSecureStorage()
        self.selectedItemID = applications.first?.id
    }

    func setGoogleTranslateAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try keychainStore.delete()
                googleTranslateAPIKey = ""
                hasGoogleTranslateAPIKey = false
                UserDefaults.standard.removeObject(forKey: Self.googleTranslateAPIKeyLegacyDefaultsKey)
                syncStatusText = "Google API key очищен"
            } else {
                try keychainStore.save(trimmed)
                googleTranslateAPIKey = trimmed
                hasGoogleTranslateAPIKey = true
                UserDefaults.standard.removeObject(forKey: Self.googleTranslateAPIKeyLegacyDefaultsKey)
                syncStatusText = "Google API key сохранен в Keychain"
            }
        } catch {
            syncStatusText = "Ошибка сохранения Google API key"
        }
    }

    func clearGoogleTranslateAPIKey() {
        setGoogleTranslateAPIKey("")
    }

    func loadFromBridge() async {
        await ensureStarredColumn()
        let loaded = (try? await PythonBridge().fetchApplications()) ?? []
        guard !loaded.isEmpty else { return }
        applications = loaded
        dataSourceLabel = "SQLite"
        ensureSelectionIsVisible()
    }

    func runProcessingPipeline() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncStatusText = "Syncing: download..."
        defer { isSyncing = false }

        let sourceDirs = availableSourceDirectories()
        guard !sourceDirs.isEmpty else {
            syncStatusText = "No source folder"
            return
        }

        let projectDir = projectRootDirectory
        let driveSyncScript = "\(projectDir)/scripts/sync_drive_rclone.sh"
        let logURL = prepareSyncLogFile(sourceDirs: sourceDirs)
        let scriptsDirEscaped = "\(projectDir)/scripts"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        appendSyncLog("Incremental mode: process only new/changed files by fingerprint (mtime_ns:size).", to: logURL)
        appendSyncLog("Translation provider: \(translationMethod.rawValue) (api_key_set=\(hasGoogleTranslateAPIKey ? "yes" : "no"))", to: logURL)

        let driveSyncExit = await runCommandLogged(
            launchPath: "/bin/bash",
            arguments: [driveSyncScript],
            currentDirectory: projectDir,
            logURL: logURL,
            stepName: "rclone sync + markdown update"
        )
        if driveSyncExit != 0 {
            appendSyncLog("Download stage failed with code \(driveSyncExit)", to: logURL)
        }

        let sourceDirLiteral = sourceDirs
            .map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") }
            .map { "Path('\($0)')" }
            .joined(separator: ", ")

let syncScript = """
import json
import sys
from pathlib import Path
sys.path.insert(0, '\(scriptsDirEscaped)')
from linkedin_applications_gui_sql import ApplicationsDB
source_dirs = [\(sourceDirLiteral)]
db_path = str(Path.home() / '.local' / 'share' / 'linkedin_apps' / 'applications.db')
manifest_path = Path.home() / 'Library' / 'Application Support' / 'LinkInJob' / 'sync_manifest.json'

def load_manifest(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
        if isinstance(data, dict):
            return {str(k): str(v) for k, v in data.items()}
    except Exception:
        return {}
    return {}

def file_fingerprint(path: Path) -> str:
    stat = path.stat()
    return f"{stat.st_mtime_ns}:{stat.st_size}"

current_manifest: dict[str, str] = {}
for source_dir in source_dirs:
    if not source_dir.exists() or not source_dir.is_dir():
        continue
    for path in source_dir.glob('*.txt'):
        try:
            resolved = str(path.resolve())
            current_manifest[resolved] = file_fingerprint(path)
        except Exception:
            continue

previous_manifest = load_manifest(manifest_path)
new_files = [path for path in current_manifest if path not in previous_manifest]
changed_existing = [path for path, fp in current_manifest.items() if path in previous_manifest and previous_manifest[path] != fp]
changed_paths = new_files + changed_existing
removed_paths = [path for path in previous_manifest if path not in current_manifest]

db = ApplicationsDB(db_path)
try:
    before = db.conn.execute("SELECT COUNT(*) FROM applications").fetchone()[0]
    db.snapshot_non_incoming_statuses()
    priority_order = {
        "incoming": 0,
        "applied": 1,
        "rejected": 2,
        "interview": 3,
        "manual_sort": 4,
    }
    files = [Path(path) for path in changed_paths]
    def file_priority(path):
        try:
            text = path.read_text(encoding='utf-8', errors='ignore')
        except Exception:
            return (99, path.name.lower())
        links = db.extract_job_links(text)
        status = db.infer_status(text, links)
        return (priority_order.get(status, 50), path.name.lower())
    files.sort(key=file_priority)
    for path in files:
        db.upsert_from_file(path.resolve())

    cur = db.conn.cursor()
    if removed_paths:
        cur.executemany("DELETE FROM applications WHERE source_file = ?", [(path,) for path in removed_paths])
    cur.execute("DELETE FROM status_pins WHERE record_key NOT IN (SELECT record_key FROM applications)")
    db.conn.commit()
    after = db.conn.execute("SELECT COUNT(*) FROM applications").fetchone()[0]
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(current_manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({
        'new_files': len(new_files),
        'changed_files': len(changed_existing),
        'removed_files': len(removed_paths),
        'new_cards': max(0, after - before),
        'removed_cards': max(0, before - after),
    }, ensure_ascii=False))
finally:
    db.close()
"""

        syncStatusText = "Syncing: SQL..."
        let (syncExit, syncOutput) = await runCommandCaptureLogged(
            launchPath: "/usr/bin/python3",
            arguments: ["-c", syncScript],
            currentDirectory: projectDir,
            logURL: logURL,
            stepName: "sqlite upsert",
            additionalEnvironment: translationEnvironment()
        )
        let metrics = parseSyncMetrics(from: syncOutput)
        let newEmails = metrics["new_files"] ?? 0
        let changedExisting = metrics["changed_files"] ?? 0
        let removedFiles = metrics["removed_files"] ?? 0
        let newCards = metrics["new_cards"] ?? 0
        let removedCards = metrics["removed_cards"] ?? 0
        appendSyncLog("After sync: +emails=\(newEmails), changed=\(changedExisting), removed_files=\(removedFiles), +cards=\(newCards), -cards=\(removedCards)", to: logURL)

        await loadFromBridge()
        if driveSyncExit != 0 {
            syncStatusText = "Sync failed: download step (\(driveSyncExit))"
        } else if syncExit != 0 {
            syncStatusText = "Sync failed: SQL step (\(syncExit))"
        } else {
            syncStatusText = "+\(newEmails) новых писем, +\(newCards) новых карточек"
        }
        appendSyncLog("Result: \(syncStatusText)", to: logURL)
    }

    func openLastSyncLog() {
        let url = syncLogFileURL()
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            _ = prepareSyncLogFile(sourceDirs: availableSourceDirectories())
        }
        NSWorkspace.shared.open(url)
    }

    var selectedItem: ApplicationItem? {
        get {
            guard let id = selectedItemID else { return nil }
            return applications.first(where: { $0.id == id })
        }
        set {
            selectedItemID = newValue?.id
        }
    }

    var filteredApplications: [ApplicationItem] {
        var items = applications.filter { matchesSidebarFilter($0) }

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let query = searchText.lowercased()
            items = items.filter {
                $0.company.lowercased().contains(query)
                    || $0.role.lowercased().contains(query)
                    || $0.location.lowercased().contains(query)
            }
        }

        switch sortOption {
        case .date:
            items.sort { lhs, rhs in
                (lhs.lastActivityDate ?? lhs.appliedDate ?? .distantPast) > (rhs.lastActivityDate ?? rhs.appliedDate ?? .distantPast)
            }
        case .age:
            items.sort { $0.daysSinceLastActivity > $1.daysSinceLastActivity }
        case .company:
            items.sort { $0.company.localizedCaseInsensitiveCompare($1.company) == .orderedAscending }
        }

        return items
    }

    var stageCounts: [Stage: Int] {
        Dictionary(uniqueKeysWithValues: Stage.allCases.map { stage in
            (stage, applications.filter { $0.effectiveStage == stage }.count)
        })
    }

    var starredCount: Int {
        applications.filter(\.starred).count
    }

    var noReplyCount: Int {
        applications.filter(\.needsFollowUp).count
    }

    func companyOccurrences(for company: String) -> Int {
        let normalized = company.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return 0 }
        return applications.reduce(into: 0) { result, item in
            if item.company.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized {
                result += 1
            }
        }
    }

    func select(stage: Stage) {
        selectedStage = stage
        sidebarFilter = .stage(stage)
        ensureSelectionIsVisible()
    }

    func selectFilter(_ filter: SidebarFilter) {
        sidebarFilter = filter
        if case .stage(let stage) = filter {
            selectedStage = stage
        }
        ensureSelectionIsVisible()
    }

    func setStage(_ stage: Stage, for item: ApplicationItem) {
        update(itemID: item.id) { $0.manualStage = stage }
        persistManualStage(for: item.id, manualStage: stage)
    }

    func resetToAuto(for item: ApplicationItem) {
        update(itemID: item.id) { $0.manualStage = nil }
        persistManualStage(for: item.id, manualStage: nil)
    }

    func toggleStar(for item: ApplicationItem) {
        update(itemID: item.id) { $0.starred.toggle() }
        guard let updated = applications.first(where: { $0.id == item.id }) else { return }
        persistStar(for: updated.id, starred: updated.starred)
    }

    func delete(item: ApplicationItem) {
        applications.removeAll { $0.id == item.id }
        ensureSelectionIsVisible()
        persistDelete(for: item)
    }

    func openJobLink(for item: ApplicationItem) {
        let candidates = jobURLCandidates(from: item.jobURL)
        guard !candidates.isEmpty else {
            openSourceFile(for: item)
            return
        }
        let opened = candidates.contains { NSWorkspace.shared.open($0) }
        if !opened {
            openSourceFile(for: item)
        }
    }

    func openSourceFile(for item: ApplicationItem) {
        let path = (item.sourceFilePath as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.open(fileURL)
            return
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }

    func copyFollowUp(for item: ApplicationItem) {
        guard item.needsFollowUp else { return }
        let template = """
        Hi \(item.company) team,

        I wanted to follow up on my application for the \(item.role) role.
        I remain very interested and would love to hear about next steps.

        Thank you,
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(template, forType: .string)
    }

    func isDescriptionTranslating(for item: ApplicationItem) -> Bool {
        translatingDescriptionIDs.contains(item.id)
    }

    func canTranslateDescriptionToRussian(for item: ApplicationItem) -> Bool {
        translationSourceDescription(for: item) != nil
    }

    func translateDescriptionToRussian(for item: ApplicationItem) {
        guard !translatingDescriptionIDs.contains(item.id) else { return }
        if effectiveManualTranslationMethod == .googleAPI && !hasGoogleTranslateAPIKey {
            syncStatusText = "Для Google Cloud API укажите ключ в Tools"
            return
        }
        guard let sourceText = translationSourceDescription(for: item) else {
            syncStatusText = "Нет текста для перевода"
            return
        }

        translatingDescriptionIDs.insert(item.id)
        syncStatusText = "Переводим описание..."

        let sourceData = Data(sourceText.utf8).base64EncodedString()
        let scriptsDirEscaped = "\(projectRootDirectory)/scripts"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let sourceFileEscaped = item.sourceFilePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let linkEscaped = (item.jobURL ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let dbIDLiteral = item.dbID.map(String.init) ?? "None"

        let script = """
import base64
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, '\(scriptsDirEscaped)')
from linkedin_applications_gui_sql import ApplicationsDB

db_path = str(Path.home() / '.local' / 'share' / 'linkedin_apps' / 'applications.db')
db = ApplicationsDB(db_path)
source_text = base64.b64decode('\(sourceData)').decode('utf-8', errors='ignore')
app_id = \(dbIDLiteral)
source_file = '\(sourceFileEscaped)'
link_url = '\(linkEscaped)'

try:
    translated = db.translate_to_russian(source_text, strict=True)
    source_norm = source_text.strip()
    translated_norm = (translated or '').strip()
    if not translated_norm:
        raise RuntimeError('Empty translation result')
    if source_norm == translated_norm and re.search(r'[\\u0590-\\u05FF\\u0600-\\u06FF]', source_norm):
        raise RuntimeError('Translation unchanged for Hebrew/Arabic source text')

    cur = db.conn.cursor()
    row = None
    if app_id is not None:
        cur.execute(
            "SELECT id, COALESCE(about_job_text_en, ''), COALESCE(about_job_text_ru, '') FROM applications WHERE id = ?",
            (app_id,),
        )
        row = cur.fetchone()
    if row is None:
        cur.execute(
            \"\"\"SELECT id, COALESCE(about_job_text_en, ''), COALESCE(about_job_text_ru, '')
            FROM applications
            WHERE source_file = ? AND COALESCE(link_url, '') = ?
            ORDER BY id DESC LIMIT 1\"\"\",
            (source_file, link_url),
        )
        row = cur.fetchone()

    if row is not None:
        row_id, about_en, _about_ru = row
        about_en = about_en or source_text
        about_ru = translated_norm
        display_text = about_ru or about_en
        cur.execute(
            \"\"\"UPDATE applications
            SET about_job_text_en = ?, about_job_text_ru = ?, about_job_text = ?, updated_at = CURRENT_TIMESTAMP
            WHERE id = ?\"\"\",
            (about_en, about_ru, display_text, row_id),
        )
        db.conn.commit()

    print(json.dumps({'translated': translated_norm, 'error': ''}, ensure_ascii=False))
except Exception as exc:
    print(json.dumps({'translated': '', 'error': str(exc)}, ensure_ascii=False))
finally:
    db.close()
"""

        Task {
            let (status, output) = await runCommandCapture(
                launchPath: "/usr/bin/python3",
                arguments: ["-c", script],
                currentDirectory: projectRootDirectory,
                additionalEnvironment: translationEnvironment(forManualTranslation: true)
            )

            translatingDescriptionIDs.remove(item.id)
            guard status == 0 else {
                syncStatusText = "Ошибка перевода"
                return
            }

            let result = parseTranslationResult(from: output)
            if let error = result.error, !error.isEmpty {
                syncStatusText = "Ошибка перевода: \(error)"
                return
            }
            guard let translated = result.translated, !translated.isEmpty else {
                syncStatusText = "Перевод не получен"
                return
            }

            update(itemID: item.id) { updated in
                if (updated.originalDescriptionText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updated.originalDescriptionText = sourceText
                }
                updated.descriptionText = translated
            }
            syncStatusText = "Описание переведено"
        }
    }

    func handleListHotkey(_ key: String) {
        guard let item = selectedItem else { return }
        switch key.lowercased() {
        case "i":
            setStage(.interview, for: item)
        case "r":
            setStage(.rejected, for: item)
        case "a":
            setStage(.archive, for: item)
        case "s":
            toggleStar(for: item)
        case "f":
            copyFollowUp(for: item)
        default:
            break
        }
    }

    func archiveSelectedItem() {
        guard let item = selectedItem else { return }
        setStage(.archive, for: item)
    }

    func moveSelectionInFilteredList(by offset: Int) {
        guard !filteredApplications.isEmpty else {
            selectedItemID = nil
            return
        }

        guard
            let selectedItemID,
            let currentIndex = filteredApplications.firstIndex(where: { $0.id == selectedItemID })
        else {
            self.selectedItemID = filteredApplications.first?.id
            return
        }

        let nextIndex = max(0, min(filteredApplications.count - 1, currentIndex + offset))
        self.selectedItemID = filteredApplications[nextIndex].id
    }

    func selectPreviousInFilteredList() {
        moveSelectionInFilteredList(by: -1)
    }

    func selectNextInFilteredList() {
        moveSelectionInFilteredList(by: 1)
    }

    func ensureSelectionVisibleInFilteredList() {
        ensureSelectionIsVisible()
    }

    func timeline(for item: ApplicationItem) -> [ActivityEvent] {
        var events: [ActivityEvent] = []

        if let appliedDate = item.appliedDate {
            events.append(ActivityEvent(date: appliedDate, type: "applied", text: "Applied to \(item.company) for \(item.role)"))
        }

        if let lastActivityDate = item.lastActivityDate, lastActivityDate != item.appliedDate {
            let text: String
            switch item.effectiveStage {
            case .interview:
                text = "Interview update received"
            case .offer:
                text = "Offer-related activity"
            case .rejected:
                text = "Rejection received"
            default:
                text = "Auto reply or status update"
            }
            events.append(ActivityEvent(date: lastActivityDate, type: "activity", text: text))
        }

        if let manualStage = item.manualStage {
            events.append(ActivityEvent(date: Date(), type: "manual", text: "Manual stage set to \(manualStage.title)"))
        }

        return events.sorted { $0.date > $1.date }
    }

    private func matchesSidebarFilter(_ item: ApplicationItem) -> Bool {
        switch sidebarFilter {
        case .stage(let stage):
            return item.effectiveStage == stage
        case .starred:
            return item.starred
        case .noReply:
            return item.needsFollowUp
        }
    }

    private func translationSourceDescription(for item: ApplicationItem) -> String? {
        if let original = item.originalDescriptionText?.trimmingCharacters(in: .whitespacesAndNewlines), !original.isEmpty {
            return original
        }
        if let current = item.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty {
            return current
        }
        return nil
    }

    private func parseTranslationResult(from output: String) -> (translated: String?, error: String?) {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let lastLine = lines.last, let data = lastLine.data(using: .utf8) else {
            return (nil, "No translation payload")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, "Invalid translation payload")
        }
        let translated = (json["translated"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (translated, error)
    }

    private var effectiveManualTranslationMethod: TranslationMethod {
        if translationMethod == .manualOnly {
            return hasGoogleTranslateAPIKey ? .googleAPI : .googleUnofficial
        }
        return translationMethod
    }

    private func translationEnvironment(forManualTranslation: Bool = false) -> [String: String] {
        let provider = forManualTranslation ? effectiveManualTranslationMethod : translationMethod
        var env: [String: String] = [
            "LINKINJOB_TRANSLATE_PROVIDER": provider.rawValue,
            "LINKEDIN_TRANSLATE_TO_RU": (forManualTranslation || translationMethod != .manualOnly) ? "1" : "0"
        ]
        if !googleTranslateAPIKey.isEmpty {
            env["LINKINJOB_GOOGLE_TRANSLATE_API_KEY"] = googleTranslateAPIKey
        }
        return env
    }

    private func loadGoogleTranslateAPIKeyFromSecureStorage() {
        do {
            if let key = try keychainStore.read(),
               !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                googleTranslateAPIKey = key
                hasGoogleTranslateAPIKey = true
                UserDefaults.standard.removeObject(forKey: Self.googleTranslateAPIKeyLegacyDefaultsKey)
                return
            }
        } catch {
            // Continue with legacy migration path.
        }

        let legacy = UserDefaults.standard.string(forKey: Self.googleTranslateAPIKeyLegacyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !legacy.isEmpty else {
            googleTranslateAPIKey = ""
            hasGoogleTranslateAPIKey = false
            return
        }

        do {
            try keychainStore.save(legacy)
            UserDefaults.standard.removeObject(forKey: Self.googleTranslateAPIKeyLegacyDefaultsKey)
            googleTranslateAPIKey = legacy
            hasGoogleTranslateAPIKey = true
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.googleTranslateAPIKeyLegacyDefaultsKey)
            googleTranslateAPIKey = legacy
            hasGoogleTranslateAPIKey = true
            syncStatusText = "Не удалось мигрировать ключ в Keychain. Сохраните ключ заново."
        }
    }

    private func ensureSelectionIsVisible() {
        if let selected = selectedItem, filteredApplications.contains(where: { $0.id == selected.id }) {
            return
        }
        selectedItemID = filteredApplications.first?.id
    }

    private func update(itemID: UUID, _ mutate: (inout ApplicationItem) -> Void) {
        guard let index = applications.firstIndex(where: { $0.id == itemID }) else { return }
        mutate(&applications[index])
        objectWillChange.send()
    }

    private func persistManualStage(for itemID: UUID, manualStage: Stage?) {
        guard let item = applications.first(where: { $0.id == itemID }) else { return }
        let manual = dbStatus(for: manualStage)
        let manualLiteral = manual.map { "'\($0)'" } ?? "None"
        let source = item.sourceFilePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let link = (item.jobURL ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let dbIDLiteral = item.dbID.map(String.init) ?? "None"

        let script = """
import sqlite3
from pathlib import Path
db_path = str(Path.home() / '.local' / 'share' / 'linkedin_apps' / 'applications.db')
conn = sqlite3.connect(db_path)
cur = conn.cursor()
db_id = \(dbIDLiteral)
source = '\(source)'
link = '\(link)'
if db_id is not None:
    cur.execute(\"\"\"SELECT id, record_key, auto_status FROM applications
WHERE id = ?\"\"\", (db_id,))
else:
    cur.execute(\"\"\"SELECT id, record_key, auto_status FROM applications
WHERE source_file = ? AND COALESCE(link_url, '') = ?
ORDER BY id DESC LIMIT 1\"\"\", (source, link))
row = cur.fetchone()
if row:
    app_id, record_key, auto_status = row
    manual_status = \(manualLiteral)
    current_status = manual_status if manual_status else (auto_status or 'incoming')
    cur.execute(\"\"\"UPDATE applications
SET manual_status = ?, current_status = ?, updated_at = CURRENT_TIMESTAMP
WHERE id = ?\"\"\", (manual_status, current_status, app_id))
    if current_status and current_status != 'incoming':
        cur.execute(\"\"\"INSERT INTO status_pins(record_key, pinned_status, updated_at)
VALUES (?, ?, CURRENT_TIMESTAMP)
ON CONFLICT(record_key) DO UPDATE SET pinned_status = excluded.pinned_status, updated_at = CURRENT_TIMESTAMP\"\"\", (record_key, current_status))
    else:
        cur.execute(\"DELETE FROM status_pins WHERE record_key = ?\", (record_key,))
conn.commit()
conn.close()
"""

        Task {
            let exit = await runCommand(
                launchPath: "/usr/bin/python3",
                arguments: ["-c", script],
                currentDirectory: projectRootDirectory
            )
            if exit != 0 {
                syncStatusText = "Save failed"
            }
        }
    }

    private func persistStar(for itemID: UUID, starred: Bool) {
        guard let item = applications.first(where: { $0.id == itemID }) else { return }
        let source = item.sourceFilePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let link = (item.jobURL ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let dbIDLiteral = item.dbID.map(String.init) ?? "None"
        let starredValue = starred ? 1 : 0

        let script = """
import sqlite3
from pathlib import Path
db_path = str(Path.home() / '.local' / 'share' / 'linkedin_apps' / 'applications.db')
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cols = [r[1] for r in cur.execute("PRAGMA table_info(applications)").fetchall()]
if "starred" not in cols:
    cur.execute("ALTER TABLE applications ADD COLUMN starred INTEGER NOT NULL DEFAULT 0")
db_id = \(dbIDLiteral)
source = '\(source)'
link = '\(link)'
if db_id is not None:
    cur.execute("UPDATE applications SET starred = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?", (\(starredValue), db_id))
else:
    cur.execute(\"\"\"UPDATE applications
SET starred = ?, updated_at = CURRENT_TIMESTAMP
WHERE id = (
    SELECT id FROM applications
    WHERE source_file = ? AND COALESCE(link_url, '') = ?
    ORDER BY id DESC LIMIT 1
)\"\"\", (\(starredValue), source, link))
conn.commit()
conn.close()
"""

        Task {
            let exit = await runCommand(
                launchPath: "/usr/bin/python3",
                arguments: ["-c", script],
                currentDirectory: projectRootDirectory
            )
            if exit != 0 {
                syncStatusText = "Star save failed"
            }
        }
    }

    private func persistDelete(for item: ApplicationItem) {
        let source = item.sourceFilePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let link = (item.jobURL ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let dbIDLiteral = item.dbID.map(String.init) ?? "None"

        let script = """
import sqlite3
from pathlib import Path
db_path = str(Path.home() / '.local' / 'share' / 'linkedin_apps' / 'applications.db')
conn = sqlite3.connect(db_path)
cur = conn.cursor()
db_id = \(dbIDLiteral)
source = '\(source)'
link = '\(link)'
if db_id is not None:
    cur.execute("DELETE FROM applications WHERE id = ?", (db_id,))
else:
    cur.execute(\"\"\"DELETE FROM applications
WHERE id = (
    SELECT id FROM applications
    WHERE source_file = ? AND COALESCE(link_url, '') = ?
    ORDER BY id DESC LIMIT 1
)\"\"\", (source, link))
cur.execute("DELETE FROM status_pins WHERE record_key NOT IN (SELECT record_key FROM applications)")
conn.commit()
conn.close()
"""

        Task {
            let exit = await runCommand(
                launchPath: "/usr/bin/python3",
                arguments: ["-c", script],
                currentDirectory: projectRootDirectory
            )
            if exit != 0 {
                syncStatusText = "Delete failed"
            }
        }
    }

    private func dbStatus(for stage: Stage?) -> String? {
        guard let stage else { return nil }
        switch stage {
        case .inbox:
            return "incoming"
        case .applied:
            return "applied"
        case .interview:
            return "interview"
        case .offer:
            return "offer"
        case .rejected:
            return "rejected"
        case .archive:
            return "archive"
        }
    }

    private func encodeSidebarFilter(_ filter: SidebarFilter) -> String {
        switch filter {
        case .stage(let stage):
            return "stage:\(stage.rawValue)"
        case .starred:
            return "starred"
        case .noReply:
            return "noReply"
        }
    }

    private func decodeSidebarFilter(_ raw: String) -> SidebarFilter? {
        if raw == "starred" { return .starred }
        if raw == "noReply" { return .noReply }
        if raw.hasPrefix("stage:") {
            let value = String(raw.dropFirst("stage:".count))
            if let stage = Stage(rawValue: value) {
                return .stage(stage)
            }
        }
        return nil
    }

    private func runCommand(
        launchPath: String,
        arguments: [String],
        currentDirectory: String,
        additionalEnvironment: [String: String] = [:]
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
                if !additionalEnvironment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(additionalEnvironment) { _, new in new }
                }
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(returning: 1)
                }
            }
        }
    }

    private func runCommandLogged(
        launchPath: String,
        arguments: [String],
        currentDirectory: String,
        logURL: URL,
        stepName: String,
        additionalEnvironment: [String: String] = [:]
    ) async -> Int32 {
        appendSyncLog("Step: \(stepName)", to: logURL)
        appendSyncLog("Command: \(launchPath) \(arguments.joined(separator: " "))", to: logURL)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
                if !additionalEnvironment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(additionalEnvironment) { _, new in new }
                }

                do {
                    let outputHandle = try FileHandle(forWritingTo: logURL)
                    outputHandle.seekToEndOfFile()
                    process.standardOutput = outputHandle
                    process.standardError = outputHandle
                    try process.run()
                    process.waitUntilExit()
                    let exitCode = process.terminationStatus
                    try? outputHandle.close()
                    DispatchQueue.main.async {
                        self.appendSyncLog("Exit code: \(exitCode)", to: logURL)
                    }
                    continuation.resume(returning: exitCode)
                } catch {
                    DispatchQueue.main.async {
                        self.appendSyncLog("Command failed to start: \(error.localizedDescription)", to: logURL)
                    }
                    continuation.resume(returning: 1)
                }
            }
        }
    }

    private func runCommandCaptureLogged(
        launchPath: String,
        arguments: [String],
        currentDirectory: String,
        logURL: URL,
        stepName: String,
        additionalEnvironment: [String: String] = [:]
    ) async -> (Int32, String) {
        appendSyncLog("Step: \(stepName)", to: logURL)
        appendSyncLog("Command: \(launchPath) \(arguments.joined(separator: " "))", to: logURL)

        let (status, output) = await runCommandCapture(
            launchPath: launchPath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            additionalEnvironment: additionalEnvironment
        )
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendSyncLog(output, to: logURL)
        }
        appendSyncLog("Exit code: \(status)", to: logURL)
        return (status, output)
    }

    private func runCommandCapture(
        launchPath: String,
        arguments: [String],
        currentDirectory: String,
        additionalEnvironment: [String: String] = [:]
    ) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
                if !additionalEnvironment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(additionalEnvironment) { _, new in new }
                }
                process.standardOutput = stdout
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (process.terminationStatus, output))
                } catch {
                    continuation.resume(returning: (1, ""))
                }
            }
        }
    }

    private func parseSyncMetrics(from output: String) -> [String: Int] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        let jsonCandidate: String
        if let line = trimmed.split(separator: "\n").last {
            jsonCandidate = String(line)
        } else {
            jsonCandidate = trimmed
        }

        guard
            let data = jsonCandidate.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        var result: [String: Int] = [:]
        for (key, value) in raw {
            if let intValue = value as? Int {
                result[key] = intValue
            } else if let strValue = value as? String, let intValue = Int(strValue) {
                result[key] = intValue
            }
        }
        return result
    }

    private func syncLogDirectoryURL() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let dir = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("LinkInJob", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func syncLogFileURL() -> URL {
        syncLogDirectoryURL().appendingPathComponent("last_sync.log")
    }

    @discardableResult
    private func prepareSyncLogFile(sourceDirs: [String]) -> URL {
        let fileURL = syncLogFileURL()
        let sourceInfo = sourceDirs.isEmpty ? "(none)" : sourceDirs.joined(separator: "\n- ")
        let header = """
        ===== LinkInJob Sync =====
        Started: \(ISO8601DateFormatter().string(from: Date()))
        Project: \(projectRootDirectory)
        Sources:
        - \(sourceInfo)

        """
        try? header.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func appendSyncLog(_ line: String, to url: URL) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Ignore log write errors, sync must continue.
        }
    }

    private func ensureStarredColumn() async {
        let script = """
import sqlite3
from pathlib import Path
db_path = str(Path.home() / '.local' / 'share' / 'linkedin_apps' / 'applications.db')
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cols = [r[1] for r in cur.execute("PRAGMA table_info(applications)").fetchall()]
if "starred" not in cols:
    cur.execute("ALTER TABLE applications ADD COLUMN starred INTEGER NOT NULL DEFAULT 0")
conn.commit()
conn.close()
"""
        _ = await runCommand(
            launchPath: "/usr/bin/python3",
            arguments: ["-c", script],
            currentDirectory: projectRootDirectory
        )
    }

    private func availableSourceDirectories() -> [String] {
        let home = NSHomeDirectory()
        let archivePath = "\(home)/Library/Application Support/DriveCVSync/LinkedIn Archive"
        let fm = FileManager.default

        if !fm.fileExists(atPath: archivePath) {
            try? fm.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
        }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: archivePath, isDirectory: &isDir), isDir.boolValue {
            return [archivePath]
        }

        return []
    }

    private static func resolveProjectRootDirectory() -> String {
        let fm = FileManager.default

        func looksLikeProjectRoot(_ path: String) -> Bool {
            let scripts = (path as NSString).appendingPathComponent("scripts")
            let parser = (path as NSString).appendingPathComponent("parser")
            let app = (path as NSString).appendingPathComponent("LinkInJob")
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: scripts, isDirectory: &isDir) && isDir.boolValue
                && fm.fileExists(atPath: parser, isDirectory: &isDir) && isDir.boolValue
                && fm.fileExists(atPath: app, isDirectory: &isDir) && isDir.boolValue
        }

        if let env = ProcessInfo.processInfo.environment["LINKEDIN_PROJECT_DIR"], !env.isEmpty, looksLikeProjectRoot(env) {
            return env
        }

        let cwd = fm.currentDirectoryPath
        if looksLikeProjectRoot(cwd) {
            return cwd
        }

        let homeCandidate = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Develop/LinkedIn")
        if looksLikeProjectRoot(homeCandidate) {
            return homeCandidate
        }

        return cwd
    }

    private func jobURLCandidates(from raw: String?) -> [URL] {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return []
        }

        if !value.lowercased().hasPrefix("http://"), !value.lowercased().hasPrefix("https://") {
            value = "https://\(value)"
        }

        var urls: [String] = []

        if let extracted = extractLinkedInJobId(from: value) {
            if value.localizedCaseInsensitiveContains("/comm/jobs/view/") {
                urls.append("https://www.linkedin.com/comm/jobs/view/\(extracted)/")
            } else {
                urls.append("https://www.linkedin.com/jobs/view/\(extracted)/")
            }
        }

        if let comps = URLComponents(string: value), let host = comps.host?.lowercased(), host.contains("linkedin.com") {
            let path = comps.path
            if let match = path.range(of: #"/(comm/)?company/([^/]+)/jobs/?$"#, options: .regularExpression) {
                let normalized = String(path[match])
                if let slugMatch = normalized.range(of: #"/(comm/)?company/([^/]+)/jobs/?$"#, options: .regularExpression) {
                    let candidate = String(normalized[slugMatch])
                    let slugParts = candidate.split(separator: "/")
                    if slugParts.count >= 3 {
                        let slug = String(slugParts[2])
                        urls.append("https://www.linkedin.com/comm/company/\(slug)/jobs/")
                        urls.append("https://www.linkedin.com/company/\(slug)/jobs/")
                    }
                }
            } else if let match = path.range(of: #"/(comm/)?company/([^/]+)/?$"#, options: .regularExpression) {
                let candidate = String(path[match])
                let slugParts = candidate.split(separator: "/")
                if slugParts.count >= 2 {
                    let slug = String(slugParts[1] == "comm" ? slugParts[2] : slugParts[1])
                    urls.append("https://www.linkedin.com/comm/company/\(slug)/jobs/")
                    urls.append("https://www.linkedin.com/company/\(slug)/jobs/")
                }
            }
        }

        if var components = URLComponents(string: value) {
            components.query = nil
            components.fragment = nil
            if let cleaned = components.url?.absoluteString {
                urls.append(cleaned)
            }
        }

        urls.append(value)

        var result: [URL] = []
        var seen = Set<String>()
        for rawURL in urls {
            if seen.contains(rawURL) { continue }
            guard let url = URL(string: rawURL), url.scheme?.hasPrefix("http") == true else { continue }
            seen.insert(rawURL)
            result.append(url)
        }
        return result
    }

    private func extractLinkedInJobId(from value: String) -> String? {
        let pattern = #"linkedin\.com/(?:comm/)?jobs/view/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(value.startIndex..., in: value)
        guard
            let match = regex.firstMatch(in: value, options: [], range: range),
            match.numberOfRanges > 1,
            let idRange = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[idRange])
    }

    private static func mockApplications() -> [ApplicationItem] {
        let companies = [
            "Apple", "Notion", "Stripe", "Figma", "Airbnb", "Shopify", "Linear", "Atlassian", "Dropbox", "Miro",
            "Canva", "GitHub", "Datadog", "Snowflake", "Nvidia", "Cloudflare", "Slack", "Asana", "Mercury", "Plaid",
            "OpenAI", "Scale", "Brex", "Deel", "Rippling", "Vercel", "Twilio", "Okta", "HubSpot", "Zapier"
        ]

        let roles = [
            "System Administrator", "IT Support Engineer", "Site Reliability Engineer", "Platform Engineer", "DevOps Engineer",
            "Infrastructure Engineer", "Security Engineer"
        ]

        let locations = ["Remote", "New York, NY", "San Francisco, CA", "Austin, TX", "Seattle, WA", "Chicago, IL"]
        let descriptions = [
            "Build and maintain reliable internal infrastructure. Partner with security and product teams.",
            "Own macOS fleet management, identity integrations, and endpoint compliance.",
            "Scale platform tooling and improve incident response workflows.",
            nil
        ]

        return (0..<30).map { index in
            let autoStage = Stage.allCases[index % Stage.allCases.count]
            let daysAgo = Int.random(in: 1...14)
            let applied = Calendar.current.date(byAdding: .day, value: -(daysAgo + Int.random(in: 1...6)), to: Date())
            let activity = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())

            return ApplicationItem(
                id: UUID(),
                dbID: nil,
                company: companies[index % companies.count],
                role: roles[index % roles.count],
                location: locations[index % locations.count],
                subject: "Your application update",
                appliedDate: applied,
                lastActivityDate: activity,
                autoStage: autoStage,
                manualStage: index % 7 == 0 ? .interview : nil,
                sourceFilePath: "\(NSHomeDirectory())/Library/Application Support/DriveCVSync/LinkedIn Archive/email_\(index).txt",
                jobURL: index % 3 == 0 ? "https://www.linkedin.com/jobs/view/\(100_000 + index)" : nil,
                descriptionText: descriptions[index % descriptions.count],
                originalDescriptionText: descriptions[index % descriptions.count],
                starred: index % 4 == 0
            )
        }
    }
}
