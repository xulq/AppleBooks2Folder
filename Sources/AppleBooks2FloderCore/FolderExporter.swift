import CryptoKit
import Darwin
import Foundation

public struct ExportReport: Sendable {
    public struct Issue: Identifiable, Sendable {
        public let id = UUID()
        public let title: String
        public let reason: String
    }

    public fileprivate(set) var exported = 0
    public fileprivate(set) var existing = 0
    public fileprivate(set) var waiting = 0
    public fileprivate(set) var skipped = 0
    public fileprivate(set) var failed = 0
    public fileprivate(set) var issues: [Issue] = []
    public fileprivate(set) var foldersNeedingAccess: Set<BooksFolder> = []
}

public actor FolderExporter {
    public static let defaultStateDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AppleBooks2Floder", isDirectory: true)

    private struct Record: Codable, Equatable {
        let name: String
        let destinationStamp: String
    }

    private let library: BooksLibrary
    private let stateDirectory: URL

    public init(library: BooksLibrary, stateDirectory: URL = defaultStateDirectory) {
        self.library = library
        self.stateDirectory = stateDirectory
    }

    public func run(to requestedFolder: URL, selection: ExportSelection = .all) throws -> ExportReport {
        let folder = try destinationFolder(requestedFolder)
        let items = try library.readSnapshot(selection)
        return try export(items, to: folder)
    }

    private func export(_ items: [BooksItem], to folder: URL) throws -> ExportReport {
        let state = stateDirectory.appendingPathComponent("v1-" + fingerprint(folder.path) + ".json")
        let previous = (try? JSONDecoder().decode([String: Record].self, from: Data(contentsOf: state))) ?? [:]
        var records: [String: Record] = [:]
        var report = ExportReport()
        for item in items {
            try Task.checkCancellation()
            do {
                guard item.downloaded, let source = item.file else { throw ExportError.notDownloaded }
                guard library.permitsOriginal(source) else { throw ExportError.originalPermission }
                let original = try Original(source.standardizedFileURL)
                let stem = Self.portableStem(item.title)
                let key = fingerprint(source.path + "\n" + stem + "\n" + original.signature)
                if let record = records[key] ?? previous[key], Self.stillPresent(record, in: folder) {
                    records[key] = record
                    report.existing += 1
                    continue
                }
                let result = try export(original, stem: stem, to: folder)
                if let stamp = try? FileStamp(result.url) {
                    records[key] = Record(name: result.url.lastPathComponent, destinationStamp: stamp.token)
                }
                if result.created { report.exported += 1 } else { report.existing += 1 }
            } catch ExportError.notDownloaded {
                report.waiting += 1
                report.issues.append(.init(title: item.title, reason: ExportError.notDownloaded.localizedDescription))
            } catch ExportError.encrypted {
                report.skipped += 1
                report.issues.append(.init(title: item.title, reason: ExportError.encrypted.localizedDescription))
            } catch ExportError.originalAccessDenied {
                report.failed += 1
                report.issues.append(.init(title: item.title, reason: ExportError.originalAccessDenied.localizedDescription))
                if let folder = item.file.flatMap(BooksFolder.containing) {
                    report.foldersNeedingAccess.insert(folder)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.failed += 1
                report.issues.append(.init(title: item.title, reason: error.localizedDescription))
            }
        }
        if records != previous { saveCache(records, to: state) }
        return report
    }

    private func destinationFolder(_ requested: URL) throws -> URL {
        guard requested.isFileURL else { throw ExportError.destination }
        let folder = requested.standardizedFileURL.resolvingSymlinksInPath()
        guard let info = try? FileStamp(folder), info.isDirectory else { throw ExportError.destination }
        let source = library.documents.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard BooksFolder.allowsDestination(folder), !folder.pathComponents.starts(with: source) else {
            throw ExportError.protectedFolder
        }
        return folder
    }

    private static func stillPresent(_ record: Record, in folder: URL) -> Bool {
        guard !record.name.isEmpty, !record.name.hasPrefix("."), !record.name.contains("/"),
              let stamp = try? FileStamp(folder.appendingPathComponent(record.name)),
              stamp.isFile else { return false }
        return stamp.token == record.destinationStamp
    }

    private func export(_ book: Original, stem: String, to folder: URL) throws -> (url: URL, created: Bool) {
        let fs = FileManager.default
        let staging = fs.temporaryDirectory.appendingPathComponent("AppleBooks2Floder-" + UUID().uuidString, isDirectory: true)
        try fs.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fs.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("book").appendingPathExtension(book.ext)
        do { try book.stage(at: staged) }
        catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
            throw ExportError.originalAccessDenied
        }
        try Task.checkCancellation()

        let size = try FileStamp(staged).size
        let digest = try Self.digest(staged)
        let pending = folder.appendingPathComponent(".applebooks2floder-" + UUID().uuidString + ".partial")
        defer { try? fs.removeItem(at: pending) }

        // The destination is shared with other apps and machines. Publish a complete
        // file with an exclusive rename so even a late collision cannot overwrite it.
        var ready = false
        for attempt in 0..<1000 {
            let tag = " [\(digest.prefix(10))]"
            let suffix = attempt == 0 ? "" : (attempt == 1 ? tag : tag + " \(attempt)")
            let target = folder.appendingPathComponent(stem + suffix).appendingPathExtension(book.ext)
            if let stamp = try? FileStamp(target) {
                if stamp.isFile, !stamp.isDataless, stamp.size == size, (try? Self.digest(target)) == digest {
                    return (target, false)
                }
                continue
            }
            if !ready {
                try copyBytes(from: staged, to: pending)
                ready = true
            }
            try Task.checkCancellation()
            if renamex_np(pending.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                return (target, true)
            }
            let failure = errno
            if failure != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
            if let stamp = try? FileStamp(target), stamp.isFile, !stamp.isDataless, stamp.size == size,
               (try? Self.digest(target)) == digest { return (target, false) }
        }
        throw ExportError.collision
    }

    private static func digest(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func portableStem(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        let clean = title.components(separatedBy: forbidden).joined(separator: "_").trimmingCharacters(in: trim)
        var stem = ""
        var length = 0
        for character in clean {
            length += String(character).utf8.count
            if length > 150 { break }
            stem.append(character)
        }
        stem = stem.trimmingCharacters(in: trim)
        let first = stem.split(separator: ".", maxSplits: 1).first?.uppercased() ?? ""
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        if reserved.contains(first) { return "_" + stem }
        return stem.isEmpty ? "Book" : stem
    }

    private func saveCache(_ records: [String: Record], to url: URL) {
        // A missing cache only means the next pass compares file contents again.
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: url, options: .atomic)
        } catch {}
    }
}
