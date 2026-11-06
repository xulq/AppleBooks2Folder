import AppKit
import AppleBooks2FloderCore
import Combine
import Foundation

@MainActor
final class SyncModel: ObservableObject {
    @Published private var target = ScopedFolder.restore(key: "destinationBookmark")
    @Published private(set) var automatic = UserDefaults.standard.bool(forKey: "automatic")
    @Published private(set) var frequency = SyncFrequency(rawValue: UserDefaults.standard.integer(forKey: "frequency"))
        ?? .defaultFrequency
    @Published private(set) var exportAll = UserDefaults.standard.integer(forKey: "exportLimit") == 0
    @Published private(set) var count: Int = {
        let count = UserDefaults.standard.integer(forKey: "exportLimit")
        return ExportSelection.allowedCounts.contains(count) ? count : 30
    }()
    @Published private(set) var order = BooksShelfOrder(rawValue: UserDefaults.standard.string(forKey: "order") ?? "") ?? .automatic
    @Published private(set) var busy = false
    @Published private(set) var report: ExportReport?
    @Published private(set) var error: String?
    @Published private(set) var foldersNeedingAccess: Set<BooksFolder> = []
    @Published private(set) var finished: Date?

    var destination: URL? { target?.url }
    var ready: Bool { target != nil }

    private var cycle: Task<Void, Never>?
    private var timer: Timer?
    private var sleeping = false
    private var choosingFolder = false
    private var manualCycle = false
    private var workspaceObservers: Set<AnyCancellable> = []
    private var sourceAccess: [BooksFolder: ScopedFolder] = [:]

    init() {
        for kind in BooksFolder.allCases {
            if let folder = ScopedFolder.restore(key: "source." + kind.rawValue, readOnly: true),
               kind.acceptsAuthorizationFolder(folder.url) {
                sourceAccess[kind] = folder
            }
        }
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in self?.willSleep() }
        }.store(in: &workspaceObservers)
        notifications.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }.store(in: &workspaceObservers)
        if automatic { start(manual: false) }
    }

    func choose() {
        chooseFolder(initial: destination, source: nil) { url in
            guard BooksFolder.allowsDestination(url) else { throw ExportError.protectedFolder }
            let folder = try ScopedFolder(selected: url)
            target = folder
            UserDefaults.standard.set(folder.bookmark, forKey: "destinationBookmark")
        }
    }

    func authorize(_ kind: BooksFolder) {
        let authorized = chooseFolder(initial: kind.url, source: kind) { url in
            let folder = try ScopedFolder(selected: url, readOnly: true)
            sourceAccess[kind] = folder
            UserDefaults.standard.set(folder.bookmark, forKey: "source." + kind.rawValue)
        }
        if authorized { run() }
    }

    @discardableResult
    private func chooseFolder(initial: URL?, source: BooksFolder?, save: (URL) throws -> Void) -> Bool {
        guard !busy, !choosingFolder else { return false }
        choosingFolder = true
        timer?.invalidate()
        defer {
            choosingFolder = false
            schedule()
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = source == nil
        let validator = source.map(BooksFolderValidator.init)
        if let source {
            panel.showsHiddenFiles = true
            panel.prompt = message("授权", "Allow Access")
            panel.message = message("请确认「\(source.label)」文件夹的只读访问。",
                                    "Confirm read-only access to the \(source.label) folder.")
            panel.accessoryView = validator?.makeAccessoryView()
            panel.isAccessoryViewDisclosed = true
        } else {
            panel.prompt = message("选择", "Choose")
            panel.message = message("选择一个本地文件夹，或已在 Mac 上配置的网盘同步文件夹。",
                                    "Choose a local folder or a cloud sync folder already configured on this Mac.")
        }
        panel.delegate = validator
        panel.directoryURL = initial
        let response = withExtendedLifetime(validator) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return false }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            try validator?.validate(url)
            try save(url)
            settingsChanged()
            return true
        } catch {
            self.error = error.localizedDescription
            report = nil
            return false
        }
    }

    func reveal() {
        guard let destination, destination.startAccessingSecurityScopedResource() else {
            error = ExportError.destination.localizedDescription
            return
        }
        defer { destination.stopAccessingSecurityScopedResource() }
        NSWorkspace.shared.open(destination)
    }

    func setExportAll(_ value: Bool) {
        guard exportAll != value else { return }
        exportAll = value
        saveScope()
    }

    func setCount(_ value: Int) {
        guard ExportSelection.allowedCounts.contains(value), count != value else { return }
        count = value
        saveScope()
    }

    func setOrder(_ value: BooksShelfOrder) {
        guard order != value else { return }
        order = value
        UserDefaults.standard.set(value.rawValue, forKey: "order")
        settingsChanged()
    }

    private func saveScope() {
        UserDefaults.standard.set(exportAll ? 0 : count, forKey: "exportLimit")
        settingsChanged()
    }

    private func settingsChanged() {
        report = nil
        error = nil
        foldersNeedingAccess = []
        finished = nil
        schedule()
    }

    func setFrequency(_ value: SyncFrequency) {
        guard frequency != value else { return }
        frequency = value
        UserDefaults.standard.set(value.rawValue, forKey: "frequency")
        schedule()
    }

    func setAutomatic(_ value: Bool) {
        automatic = value
        UserDefaults.standard.set(value, forKey: "automatic")
        if value { start(manual: false) }
        else {
            if !manualCycle { cycle?.cancel() }
            schedule()
        }
    }

    private func willSleep() {
        sleeping = true
        if !manualCycle { cycle?.cancel() }
        schedule()
    }

    private func didWake() {
        sleeping = false
        if automatic { start(manual: false) }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automatic, ready, !sleeping, !choosingFolder, cycle == nil else { return }
        let delay = frequency.interval
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automatic else { return }
                self.start(manual: false)
            }
        }
        timer?.tolerance = min(15, delay * 0.2)
    }

    func run() { start(manual: true) }

    private func start(manual: Bool) {
        guard let destination, cycle == nil, !sleeping, !choosingFolder else { return }
        timer?.invalidate()
        busy = true
        manualCycle = manual
        let selection: ExportSelection = exportAll ? .all : .first(count, order: order)
        cycle = Task(priority: .utility) {
            defer {
                busy = false
                cycle = nil
                manualCycle = false
                schedule()
            }
            do {
                guard destination.startAccessingSecurityScopedResource() else { throw ExportError.destination }
                defer { destination.stopAccessingSecurityScopedResource() }
                let accessible = sourceAccess.values.map(\.url).filter { $0.startAccessingSecurityScopedResource() }
                defer { accessible.forEach { $0.stopAccessingSecurityScopedResource() } }
                let exporter = FolderExporter(library: BooksLibrary())
                let result = try await exporter.run(to: destination, selection: selection)
                try Task.checkCancellation()
                report = result
                foldersNeedingAccess = result.foldersNeedingAccess
                finished = Date()
                error = nil
            } catch is CancellationError {
                // Retry the export on the next automatic check.
            } catch {
                self.error = error.localizedDescription
                report = nil
                if case ExportError.permission = error { foldersNeedingAccess = [.library] }
                else { foldersNeedingAccess = [] }
            }
        }
    }
}

@MainActor
private final class BooksFolderValidator: NSObject, NSOpenSavePanelDelegate {
    private static let goToFolderShortcut = "⌘ Command + ⇧ Shift + G"
    let folder: BooksFolder

    init(_ folder: BooksFolder) { self.folder = folder }

    func panel(_ sender: Any, validate url: URL) throws { try validate(url) }

    func validate(_ url: URL) throws {
        guard folder.acceptsAuthorizationFolder(url) else {
            throw NSError(domain: "AppleBooks2Floder.BooksFolder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message("请前往「\(folder.label)」文件夹。",
                                                    "Go to the \(folder.label) folder to continue."),
                NSLocalizedRecoverySuggestionErrorKey: message(
                    "在授权面板点击「复制图书路径」。按 \(Self.goToFolderShortcut) 打开「前往文件夹」，粘贴路径并回车，再点击「授权」。",
                    "Click Copy Books Path in the access panel. Press \(Self.goToFolderShortcut) to open Go to Folder, paste the path and press Return, then click Allow Access.")
            ])
        }
    }

    func makeAccessoryView() -> NSView {
        let instruction = NSTextField(wrappingLabelWithString: message(
            "如果面板停在其他位置，请复制下方路径。按 \(Self.goToFolderShortcut) 打开「前往文件夹」，粘贴路径并回车，再点「授权」。",
            "If the panel opens elsewhere, copy this path. Press \(Self.goToFolderShortcut) to open Go to Folder, paste the path and press Return, then click Allow Access."))
        instruction.preferredMaxLayoutWidth = 470

        let path = NSTextField(labelWithString: folder.url.path)
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        path.isSelectable = true
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let copy = NSButton(title: message("复制图书路径", "Copy Books Path"), target: self, action: #selector(copyPath))
        let row = NSStackView(views: [path, copy])
        row.alignment = .centerY
        row.spacing = 8

        let content = NSStackView(views: [instruction, row])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        instruction.widthAnchor.constraint(lessThanOrEqualToConstant: 470).isActive = true
        row.widthAnchor.constraint(equalToConstant: 470).isActive = true
        content.frame.size = content.fittingSize
        return content
    }

    @objc private func copyPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(folder.url.path, forType: .string)
    }
}
