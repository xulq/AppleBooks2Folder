import Foundation
import SQLite3

struct BooksItem {
    let title: String
    let file: URL?
    let downloaded: Bool
}

public struct BooksLibrary: Sendable {
    let documents: URL
    private let originalRoots: [URL]

    public init() { self.init(userHome: BooksFolder.userHome) }

    init(userHome: URL) {
        self.init(documents: BooksFolder.library.url(in: userHome),
                  additionalOriginalFolders: [BooksFolder.iCloud.url(in: userHome), BooksFolder.legacy.url(in: userHome)])
    }

    public init(documents: URL, additionalOriginalFolders: [URL] = []) {
        self.documents = documents
        originalRoots = ([documents] + additionalOriginalFolders).map(\.standardizedFileURL)
    }

    private var catalogDirectory: URL { documents.appendingPathComponent("BKLibrary", isDirectory: true) }

    private func databaseFile() throws -> URL {
        let canonical = catalogDirectory.appendingPathComponent("BKLibrary-1-091020131601.sqlite")
        // Opening a known file can request App Data access even when a
        // directory listing was silently denied.
        let descriptor = open(canonical.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor >= 0 {
            close(descriptor)
            return canonical
        }
        if errno == EACCES || errno == EPERM { throw ExportError.permission }

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: catalogDirectory, includingPropertiesForKeys: nil)
        } catch {
            switch (error as NSError).code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: throw ExportError.noLibrary
            default: throw ExportError.permission
            }
        }

        let candidates = files.filter {
            $0.lastPathComponent.range(of: #"^BKLibrary-[0-9]+-[0-9]+\.sqlite$"#, options: .regularExpression) != nil
        }
        let preferred = candidates.first { $0.lastPathComponent == canonical.lastPathComponent }
        guard let file = preferred ?? (candidates.count == 1 ? candidates.first : nil) else {
            throw candidates.isEmpty ? ExportError.noLibrary : ExportError.ambiguousLibrary
        }
        return file
    }

    func permitsOriginal(_ file: URL) -> Bool {
        // Check the path before asking the filesystem to resolve links, then
        // verify that the physical path also stays inside an authorized root.
        let file = file.standardizedFileURL
        guard let root = originalRoots.first(where: { file.pathComponents.starts(with: $0.pathComponents) }) else {
            return false
        }
        return file.resolvingSymlinksInPath().pathComponents.starts(with: root.resolvingSymlinksInPath().pathComponents)
    }

    func readSnapshot(_ selection: ExportSelection) throws -> [BooksItem] {
        do {
            let file = try databaseFile()
            let fs = FileManager.default
            let workspace = fs.temporaryDirectory.appendingPathComponent("AppleBooks2Floder-Catalog-" + UUID().uuidString)
            try fs.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fs.removeItem(at: workspace) }
            let local = workspace.appendingPathComponent("catalog.sqlite")
            let sidecar = URL(fileURLWithPath: file.path + "-wal")
            let localSidecar = URL(fileURLWithPath: local.path + "-wal")

            // SQLite can create a shared-memory index even on a read-only
            // connection. Copy a stable database/WAL pair so all such writes
            // occur in our private temporary directory.
            for _ in 0..<3 {
                try Task.checkCancellation()
                guard let main = try snapshotStamp(file) else { continue }
                let wal = try snapshotStamp(sidecar)
                do {
                    try copyBytes(from: file, to: local)
                    if wal != nil { try copyBytes(from: sidecar, to: localSidecar) }
                    if try snapshotStamp(file) == main, try snapshotStamp(sidecar) == wal {
                        try fs.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
                        if wal != nil {
                            try fs.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localSidecar.path)
                        }
                        return try read(selection, using: BooksReadDatabase(snapshot: local))
                    }
                } catch let error as POSIXError where error.code == .ENOENT {
                    // Books may have just checkpointed and removed its WAL.
                }
                try? fs.removeItem(at: local)
                try? fs.removeItem(at: localSidecar)
            }
            throw ExportError.invalidLibrary
        } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
            throw ExportError.permission
        }
    }

    private func snapshotStamp(_ file: URL) throws -> String? {
        do {
            let stamp = try FileStamp(file)
            guard stamp.isFile, !stamp.isDataless else { throw ExportError.invalidLibrary }
            return stamp.token
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
    }

    /// Read the selected prefix before inspecting any original files.
    private func read(_ selection: ExportSelection, using db: BooksReadDatabase) throws -> [BooksItem] {
        let limit: Int?
        let requestedOrder: BooksShelfOrder
        switch selection {
        case .all: limit = nil; requestedOrder = .automatic
        case let .first(count, order):
            guard ExportSelection.allowedCounts.contains(count) else { throw ExportError.invalidCount }
            limit = count
            requestedOrder = order
        }
        try db.execute("BEGIN")
        defer { if sqlite3_get_autocommit(db.handle) == 0 { try? db.execute("ROLLBACK") } }

        let columns = try db.columns("ZBKLIBRARYASSET")
        guard Set(["ZASSETID", "ZTITLE", "ZPATH", "ZCONTENTTYPE"]).isSubset(of: columns) else {
            throw ExportError.invalidLibrary
        }

        // Read Books' All collection, including its optional manual ranks.
        var order = requestedOrder
        var ranks: [String: Double] = [:]
        if limit != nil, order == .automatic || order == .manual {
            let collection = try db.allCollection()
            if order == .automatic {
                guard let collection, let resolved = BooksShelfOrder(booksMode: collection.mode ?? "7") else {
                    throw ExportError.sortUnavailable
                }
                order = resolved
            }
            if order == .manual, let id = collection?.id,
               try Set(["ZASSETID", "ZSORTKEY", "ZCOLLECTION"]).isSubset(of: db.columns("ZBKCOLLECTIONMEMBER")) {
                try db.query("SELECT ZASSETID, ZSORTKEY FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION = \(id)") { row in
                    if let asset = columnText(row, 0), let rank = columnNumber(row, 1) { ranks[asset] = rank }
                }
            }
        }

        let optional = [
            "ZSTATE",
            order == .author ? "ZAUTHOR" : "NULL",
            order == .title || order == .author ? "ZSORTTITLE" : "NULL",
            order == .author ? "ZSORTAUTHOR" : "NULL",
            order == .recent ? "ZLASTOPENDATE" : "NULL",
            order == .recent ? "ZCREATIONDATE" : "NULL",
            order == .recent || order == .manual ? "ZSORTKEY" : "NULL"
        ]
        let fields = (["ZASSETID", "ZTITLE", "ZPATH", "ZCONTENTTYPE"] +
                      optional.map { columns.contains($0) ? $0 : "NULL" }).joined(separator: ", ")
        let filters = ["ZISDELETED", "ZISSTOREAUDIOBOOK"].filter(columns.contains)
            .map { "COALESCE(\($0), 0) != 1" }
        let predicate = filters.isEmpty ? "" : " WHERE " + filters.joined(separator: " AND ")
        var candidates: [Candidate] = []
        try db.query("SELECT \(fields) FROM ZBKLIBRARYASSET\(predicate) ORDER BY ZASSETID") { row in
            let file = columnText(row, 2).flatMap(Self.fileURL)
            let ext = file?.pathExtension.lowercased()
            let type = sqlite3_column_int(row, 3)
            guard ext == "pdf" || ext == "epub" || (file == nil && [1, 3].contains(type)) else { return }
            let catalogTitle = columnText(row, 1)
            let title = catalogTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = file?.deletingPathExtension().lastPathComponent ?? message("未命名图书", "Untitled book")
            let item = BooksItem(title: title.flatMap { $0.isEmpty ? nil : $0 } ?? fallback,
                                 file: file, downloaded: sqlite3_column_int(row, 4) != 3)
            candidates.append(Candidate(
                item: item, id: columnText(row, 0) ?? "",
                title: columnText(row, 6) ?? catalogTitle ?? "",
                author: columnText(row, 7) ?? columnText(row, 5) ?? "",
                opened: columnNumber(row, 8) ?? 0, created: columnNumber(row, 9) ?? 0,
                rank: columnNumber(row, 10) ?? 0))
        }
        try db.execute("COMMIT")
        guard let limit else { return candidates.map(\.item) }
        candidates.sort { $0.precedes($1, order: order, manualRanks: ranks) }
        return candidates.prefix(limit).map(\.item)
    }

    private static func fileURL(_ path: String) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let url = URL(string: path), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost", url.path.hasPrefix("/") else { return nil }
        return url
    }

    private struct Candidate {
        let item: BooksItem
        let id: String
        let title: String
        let author: String
        let opened: Double
        let created: Double
        let rank: Double

        func precedes(_ other: Self, order: BooksShelfOrder, manualRanks: [String: Double]) -> Bool {
            switch order {
            case .recent:
                if opened != other.opened { return opened > other.opened }
                if created != other.created { return created > other.created }
                if rank != other.rank { return rank > other.rank }
            case .manual:
                let lhs = manualRanks[id] ?? rank, rhs = manualRanks[other.id] ?? other.rank
                if lhs != rhs { return lhs > rhs }
            case .author, .title:
                if order == .author {
                    let comparison = author.localizedStandardCompare(other.author)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                }
                let comparison = title.localizedStandardCompare(other.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .automatic: break
            }
            return id < other.id
        }
    }
}

private final class BooksReadDatabase {
    let handle: OpaquePointer

    init(snapshot: URL) throws {
        var handle: OpaquePointer?
        // SQLite may rebuild the WAL index in this private snapshot. SQL queries remain read-only.
        guard sqlite3_open_v2(snapshot.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw ExportError.invalidLibrary
        }
        sqlite3_busy_timeout(handle, 500)
        guard sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw ExportError.invalidLibrary
        }
        self.handle = handle
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw ExportError.invalidLibrary }
    }

    func columns(_ table: String) throws -> Set<String> {
        var columns = Set<String>()
        try query("PRAGMA table_info(\(table))") { row in
            if let name = columnText(row, 1) { columns.insert(name.uppercased()) }
        }
        return columns
    }

    func allCollection() throws -> (id: Int64?, mode: String?)? {
        let columns = try columns("ZBKCOLLECTION")
        guard columns.contains("ZCOLLECTIONID"), columns.contains("ZSORTMODE") else { return nil }
        let key = columns.contains("Z_PK") ? "Z_PK" : "NULL"
        var collection: (id: Int64?, mode: String?)?
        try query("""
            SELECT \(key), ZSORTMODE FROM ZBKCOLLECTION
            WHERE LOWER(ZCOLLECTIONID) IN ('all', 'allbooks', 'all_collection_id', 'collections_allbooks') LIMIT 1
            """) { row in
            let id = sqlite3_column_type(row, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 0)
            collection = (id, columnText(row, 1))
        }
        return collection
    }

    func query(_ sql: String, consume: (OpaquePointer?) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw ExportError.invalidLibrary }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: consume(statement)
            case SQLITE_DONE: return
            default: throw ExportError.invalidLibrary
            }
        }
    }
}

private func columnText(_ row: OpaquePointer?, _ column: Int32) -> String? {
    sqlite3_column_text(row, column).map { String(cString: $0) }
}

private func columnNumber(_ row: OpaquePointer?, _ column: Int32) -> Double? {
    guard sqlite3_column_type(row, column) != SQLITE_NULL else { return nil }
    let value = sqlite3_column_double(row, column)
    return value.isFinite ? value : nil
}
