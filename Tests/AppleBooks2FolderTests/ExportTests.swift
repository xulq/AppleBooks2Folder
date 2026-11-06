import CoreGraphics
import Foundation
import SQLite3
import XCTest
import ZIPFoundation
@testable import AppleBooks2FolderCore

final class ExportTests: XCTestCase {
    func testWALCatalogCopiesPDFAndPackagesEPUB() async throws {
        let fixture = try Fixture()
        let pdf = try fixture.pdf("原书.pdf")
        let package = try fixture.epub("folder.epub")
        try fixture.add("1", title: "中文 / 卷", file: pdf)
        try fixture.add("2", title: "EPUB 样本", file: package, fileURL: true)
        try fixture.add("3", title: "deleted", file: pdf, deleted: true)
        try fixture.add("4", title: "audio", file: pdf, audiobook: true)
        try fixture.add("5", title: "Cloud", state: 3)
        let before = try Data(contentsOf: fixture.database)
        let wal = URL(fileURLWithPath: fixture.database.path + "-wal")
        let walBefore = try Data(contentsOf: wal)

        let report = try await fixture.export()
        XCTAssertEqual(report.exported, 2, "\(report.issues)")
        XCTAssertEqual(report.waiting, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.database), before)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
        let original = try Data(contentsOf: pdf)
        let output = fixture.destination.appendingPathComponent("中文 _ 卷.pdf")
        XCTAssertEqual(try Data(contentsOf: output), original)

        let exportedEPUB = fixture.destination.appendingPathComponent("EPUB 样本.epub")
        let bytes = try Data(contentsOf: exportedEPUB)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertEqual(Array(bytes[8...9]), [0, 0])
        XCTAssertEqual(Array(bytes[28...29]), [0, 0])
        XCTAssertEqual(String(decoding: bytes[30..<58], as: UTF8.self), "mimetypeapplication/epub+zip")
        let archive = try Archive(url: exportedEPUB, accessMode: .read)
        XCTAssertNotNil(archive["OPS/book.opf"])
        XCTAssertNotNil(archive["OPS/第一章.xhtml"])

        let repeatReport = try await fixture.export()
        XCTAssertEqual(repeatReport.exported, 0)
        XCTAssertEqual(repeatReport.existing, 2)
        // Restart with an empty cache and verify content deduplication still works.
        try FileManager.default.removeItem(at: fixture.state)
        let afterCacheLoss = try await fixture.export()
        XCTAssertEqual(afterCacheLoss.exported, 0)
        XCTAssertEqual(afterCacheLoss.existing, 2)
    }

    func testSameTitleAndEditedDestinationArePreserved() async throws {
        let fixture = try Fixture()
        let first = try fixture.pdf("first.pdf", width: 100)
        let second = try fixture.pdf("second.pdf", width: 200)
        try fixture.add("1", title: "CON", file: first)
        try fixture.add("2", title: "CON", file: second)
        let existing = fixture.destination.appendingPathComponent("_CON.pdf")
        let sentinel = Data("A file already managed by the user".utf8)
        try sentinel.write(to: existing)

        let report = try await fixture.export()
        XCTAssertEqual(report.exported, 2, "\(report.issues)")
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        let copies = try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path)
            .filter { $0.hasPrefix("_CON [") }.sorted()
        XCTAssertEqual(copies.count, 2)
        guard let name = copies.first else { return }
        let edited = fixture.destination.appendingPathComponent(name)
        try sentinel.write(to: edited, options: .atomic)

        let retry = try await fixture.export()
        XCTAssertEqual(retry.exported, 1)
        XCTAssertEqual(retry.existing, 1)
        XCTAssertEqual(try Data(contentsOf: edited), sentinel)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)

        try fixture.exec("UPDATE ZBKLIBRARYASSET SET ZISDELETED = 1")
        let afterDeletion = try await fixture.export()
        XCTAssertEqual(afterDeletion.exported, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).count, 4)
    }

    func testSkipsProtectedAndUnavailableOriginals() async throws {
        let fixture = try Fixture()
        let protected = try fixture.epub("protected.epub")
        try Data("<rights/>".utf8).write(to: protected.appendingPathComponent("META-INF/rights.xml"))
        let pdf = try fixture.pdf("protected.pdf", password: "password")
        let cloud = try fixture.epub("cloud.epub")
        try Data().write(to: cloud.appendingPathComponent("OPS/.chapter.xhtml.icloud"))
        let invalid = try fixture.epub("invalid.epub")
        try FileManager.default.removeItem(at: invalid.appendingPathComponent("OPS/book.opf"))
        let linked = fixture.documents.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: pdf)
        try fixture.add("1", title: "Protected EPUB", file: protected)
        try fixture.add("2", title: "Protected PDF", file: pdf)
        try fixture.add("3", title: "Cloud", file: cloud)
        try fixture.add("4", title: "Missing", file: fixture.documents.appendingPathComponent("absent.pdf"))
        try fixture.add("5", title: "Incomplete", file: invalid)
        try fixture.add("6", title: "Linked", file: linked)
        let report = try await fixture.export()
        XCTAssertEqual(report.exported, 0)
        XCTAssertEqual(report.skipped, 2, "\(report.issues)")
        XCTAssertEqual(report.waiting, 2)
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    func testPackedEPUBIsCopiedAsIsAndRemovedDestinationIsNotRecreated() async throws {
        let fixture = try Fixture()
        let unpacked = try fixture.epub("source.epub")
        let source = fixture.documents.appendingPathComponent("packed.epub")
        try Original(unpacked).stage(at: source)
        try fixture.add("1", title: "Packed", file: source)
        let report = try await fixture.export()
        XCTAssertEqual(report.exported, 1)
        XCTAssertEqual(try Data(contentsOf: source),
                       try Data(contentsOf: fixture.destination.appendingPathComponent("Packed.epub")))
        try FileManager.default.removeItem(at: fixture.destination)
        do {
            _ = try await fixture.export()
            XCTFail("A missing destination should fail without recreating it")
        } catch ExportError.destination {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testRejectsDestinationInsideBooks() async throws {
        let fixture = try Fixture()
        do {
            _ = try await fixture.export(to: fixture.documents)
            XCTFail("Apple Books must remain read-only")
        } catch ExportError.protectedFolder {}
    }

    func testConcurrentExportersPublishOneCompleteCopy() async throws {
        let fixture = try Fixture()
        let source = try fixture.pdf("one.pdf")
        try fixture.add("1", title: "One", file: source)
        let library = BooksLibrary(documents: fixture.documents)
        let destination = fixture.destination
        let first = FolderExporter(library: library, stateDirectory: fixture.state)
        let second = FolderExporter(library: library, stateDirectory: fixture.state)

        async let firstRun = first.run(to: destination)
        async let secondRun = second.run(to: destination)
        let reports = try await [firstRun, secondRun]
        XCTAssertEqual(reports.map(\.exported).reduce(0, +), 1)
        XCTAssertEqual(reports.map(\.existing).reduce(0, +), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["One.pdf"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("One.pdf")), try Data(contentsOf: source))
    }

    func testFirstBooksFollowsTheAllCollectionAndPreservesEarlierExports() async throws {
        let fixture = try Fixture()
        try fixture.add("1", title: "Zebra", file: fixture.pdf("first.pdf"))
        try fixture.add("2", title: "Apple", file: fixture.pdf("second.pdf"))
        try fixture.add("3", title: "Ant", state: 3)
        try fixture.add("4", title: "Aardvark", file: fixture.pdf("audio.pdf"), audiobook: true)
        try fixture.exec("""
            CREATE TABLE ZBKCOLLECTION (Z_PK INTEGER, ZCOLLECTIONID TEXT, ZSORTMODE INTEGER);
            INSERT INTO ZBKCOLLECTION VALUES (1, 'All_Collection_ID', 3);
            """)
        let exporter = FolderExporter(library: BooksLibrary(documents: fixture.documents), stateDirectory: fixture.state)
        let firstTwo = try await exporter.run(to: fixture.destination, selection: .first(2, order: .automatic))
        XCTAssertEqual(firstTwo.exported, 1)
        XCTAssertEqual(firstTwo.waiting, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), ["Apple.pdf"])
        let narrower = try await exporter.run(to: fixture.destination, selection: .first(1, order: .automatic))
        XCTAssertEqual(narrower.exported, 0)
        XCTAssertEqual(narrower.waiting, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), ["Apple.pdf"])
    }

    func testSortOverridesAndManualRanksMatchBooks() async throws {
        let fixture = try Fixture()
        try fixture.add("1", title: "Beta", file: fixture.pdf("one.pdf"))
        try fixture.add("2", title: "Alpha", file: fixture.pdf("two.pdf"))
        try fixture.exec("""
            ALTER TABLE ZBKLIBRARYASSET ADD COLUMN ZLASTOPENDATE REAL;
            ALTER TABLE ZBKLIBRARYASSET ADD COLUMN ZAUTHOR TEXT;
            ALTER TABLE ZBKLIBRARYASSET ADD COLUMN ZSORTKEY REAL;
            UPDATE ZBKLIBRARYASSET SET ZLASTOPENDATE = 10, ZAUTHOR = 'Z', ZSORTKEY = 1 WHERE ZASSETID = '1';
            UPDATE ZBKLIBRARYASSET SET ZLASTOPENDATE = 2, ZAUTHOR = 'A', ZSORTKEY = 2 WHERE ZASSETID = '2';
            CREATE TABLE ZBKCOLLECTION (Z_PK INTEGER, ZCOLLECTIONID TEXT, ZSORTMODE INTEGER);
            INSERT INTO ZBKCOLLECTION VALUES (7, 'all', 999);
            CREATE TABLE ZBKCOLLECTIONMEMBER (ZASSETID TEXT, ZCOLLECTION INTEGER, ZSORTKEY REAL);
            INSERT INTO ZBKCOLLECTIONMEMBER VALUES ('1', 7, 10), ('2', 7, 5);
            """)
        let library = BooksLibrary(documents: fixture.documents)
        XCTAssertThrowsError(try library.readSnapshot(.first(1, order: .automatic))) { error in
            guard case ExportError.sortUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try library.readSnapshot(.first(1, order: .recent)).map(\.title), ["Beta"])
        XCTAssertEqual(try library.readSnapshot(.first(1, order: .author)).map(\.title), ["Alpha"])
        XCTAssertEqual(try library.readSnapshot(.first(1, order: .manual)).map(\.title), ["Beta"])
        XCTAssertThrowsError(try library.readSnapshot(.first(2001, order: .title)))
        XCTAssertEqual(try library.readSnapshot(.all).count, 2)
    }

    func testOnlyAuthorizedSourceFoldersAreExported() async throws {
        let fixture = try Fixture()
        let outside = fixture.root.appendingPathComponent("CloudBooks", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let cloud = outside.appendingPathComponent("book.pdf")
        try FileManager.default.moveItem(at: fixture.pdf("cloud.pdf"), to: cloud)
        try fixture.add("1", title: "Cloud", file: cloud)

        let redirected = fixture.documents.appendingPathComponent("redirected", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: outside)
        let library = BooksLibrary(documents: fixture.documents)
        XCTAssertFalse(library.permitsOriginal(redirected.appendingPathComponent("book.pdf")))

        let ungranted = try await fixture.export()
        XCTAssertEqual(ungranted.failed, 1)
        XCTAssertEqual(ungranted.issues.first?.reason, ExportError.originalPermission.localizedDescription)
        XCTAssertEqual(ungranted.exported, 0)

        let authorizedLibrary = BooksLibrary(documents: fixture.documents, additionalOriginalFolders: [outside])
        let exporter = FolderExporter(library: authorizedLibrary, stateDirectory: fixture.state)
        let granted = try await exporter.run(to: fixture.destination)
        XCTAssertEqual(granted.exported, 1)
    }

    func testDiscoversCatalogAndOriginalsInStandardBooksFolders() async throws {
        let fixture = try Fixture()
        try fixture.add("1", title: "Local", file: fixture.pdf("local.pdf"))
        for (id, kind, title) in [("2", BooksFolder.iCloud, "Cloud"), ("3", .legacy, "Legacy")] {
            let directory = kind.url(in: fixture.root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = directory.appendingPathComponent(title + ".pdf")
            try FileManager.default.moveItem(at: fixture.pdf(id + ".pdf"), to: original)
            try fixture.add(id, title: title, file: original)
        }
        let exporter = FolderExporter(library: BooksLibrary(userHome: fixture.root), stateDirectory: fixture.state)
        let report = try await exporter.run(to: fixture.destination)
        XCTAssertEqual(report.exported, 3)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path)),
                       ["Local.pdf", "Cloud.pdf", "Legacy.pdf"])
    }

    func testReadOnlyCatalogDoesNotCreateSidecars() async throws {
        let fixture = try Fixture()
        try fixture.add("1", title: "Local", file: fixture.pdf("local.pdf"))
        try fixture.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        fixture.closeDatabase()
        for suffix in ["-wal", "-shm"] {
            let sidecar = fixture.database.path + suffix
            if FileManager.default.fileExists(atPath: sidecar) {
                try FileManager.default.removeItem(atPath: sidecar)
            }
        }
        let dir = fixture.database.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files, [fixture.database.lastPathComponent])
        let original = try Data(contentsOf: fixture.database)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let report = try await fixture.export()
        XCTAssertEqual(report.exported, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), files)
        XCTAssertEqual(try Data(contentsOf: fixture.database), original)
    }

    func testCatalogDenialCanBeRetriedAfterAccessChanges() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires a non-root user") }
        let fixture = try Fixture()
        try fixture.add("1", title: "Local", file: fixture.pdf("local.pdf"))
        let fs = FileManager.default
        let exporter = FolderExporter(library: BooksLibrary(userHome: fixture.root), stateDirectory: fixture.state)

        try fs.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.database.path)
        defer { try? fs.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.database.path) }
        do {
            _ = try await exporter.run(to: fixture.destination)
            XCTFail("A denied catalog must request Books folder access")
        } catch ExportError.permission {}
        XCTAssertTrue(try fs.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)

        try fs.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.database.path)
        let report = try await exporter.run(to: fixture.destination)
        XCTAssertEqual(report.exported, 1)
    }

    func testSyncFrequencyPresetsAndDefault() {
        XCTAssertEqual(SyncFrequency.defaultFrequency, .fifteenMinutes)
        XCTAssertNil(SyncFrequency(rawValue: 0))
        XCTAssertEqual(SyncFrequency.allCases.map(\.interval), [60, 300, 900, 1800, 3600])
    }

    func testBooksAuthorizationRejectsOrdinaryDocumentsAndAcceptsDataVolumeAlias() {
        let library = BooksFolder.library
        let personalDocuments = BooksFolder.userHome.appendingPathComponent("Documents", isDirectory: true)
        XCTAssertTrue(library.acceptsAuthorizationFolder(library.url))
        XCTAssertFalse(library.acceptsAuthorizationFolder(personalDocuments))
        XCTAssertFalse(library.acceptsAuthorizationFolder(library.url.appendingPathComponent("BKLibrary", isDirectory: true)))
        if library.url.path.hasPrefix("/Users/") {
            let alias = URL(fileURLWithPath: "/System/Volumes/Data" + library.url.path, isDirectory: true)
            XCTAssertTrue(library.acceptsAuthorizationFolder(alias))
        }
    }
}

private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppleBooks2FolderTests-" + UUID().uuidString)
    var documents: URL { BooksFolder.library.url(in: root) }
    var destination: URL { root.appendingPathComponent("Destination") }
    var state: URL { root.appendingPathComponent("State") }
    var database: URL { documents.appendingPathComponent("BKLibrary/BKLibrary-1-091020131601.sqlite") }
    private var handle: OpaquePointer?

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        guard sqlite3_open(database.path, &handle) == SQLITE_OK else { throw ExportError.invalidLibrary }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE ZBKLIBRARYASSET (
                ZASSETID TEXT, ZTITLE TEXT, ZPATH TEXT, ZCONTENTTYPE INTEGER, ZSTATE INTEGER,
                ZISDELETED INTEGER, ZISSTOREAUDIOBOOK INTEGER
            );
            """)
    }

    deinit {
        closeDatabase()
        try? FileManager.default.removeItem(at: root)
    }

    func closeDatabase() {
        sqlite3_close(handle)
        handle = nil
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw ExportError.invalidLibrary }
    }

    func add(_ id: String, title: String, file: URL? = nil, fileURL: Bool = false,
             state: Int = 1, deleted: Bool = false, audiobook: Bool = false) throws {
        let path = file.map { fileURL ? $0.absoluteString : $0.path }
        func literal(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        try exec("""
            INSERT INTO ZBKLIBRARYASSET VALUES (
                \(literal(id)), \(literal(title)), \(path.map(literal) ?? "NULL"),
                \(file?.pathExtension == "pdf" ? 3 : 1), \(state), \(deleted ? 1 : 0), \(audiobook ? 1 : 0)
            )
            """)
    }

    func pdf(_ name: String, width: CGFloat = 100, password: String? = nil) throws -> URL {
        let url = documents.appendingPathComponent(name)
        var bounds = CGRect(x: 0, y: 0, width: width, height: 100)
        let info = password.map { [kCGPDFContextUserPassword: $0, kCGPDFContextOwnerPassword: $0] as CFDictionary }
        guard let context = CGContext(url as CFURL, mediaBox: &bounds, info) else { throw ExportError.invalidBook }
        context.beginPDFPage(nil)
        context.fill(bounds)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    func epub(_ name: String) throws -> URL {
        let url = documents.appendingPathComponent(name)
        for subfolder in ["META-INF", "OPS"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(subfolder), withIntermediateDirectories: true)
        }
        let xml = """
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
        try Data(xml.utf8).write(to: url.appendingPathComponent("META-INF/container.xml"))
        let opf = """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="id">urn:example:sample</dc:identifier>
                <dc:title>Sample</dc:title><dc:language>en</dc:language>
                <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
              </metadata>
              <manifest>
                <item id="chapter" href="第一章.xhtml" media-type="application/xhtml+xml"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              </manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """
        let chapter = """
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>Sample Chapter</title></head><body><p>Sample chapter text.</p></body>
            </html>
            """
        let nav = """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <head><title>Contents</title></head>
              <body><nav epub:type="toc"><ol><li><a href="第一章.xhtml">Sample Chapter</a></li></ol></nav></body>
            </html>
            """
        try Data(opf.utf8).write(to: url.appendingPathComponent("OPS/book.opf"))
        try Data(chapter.utf8).write(to: url.appendingPathComponent("OPS/第一章.xhtml"))
        try Data(nav.utf8).write(to: url.appendingPathComponent("OPS/nav.xhtml"))
        return url
    }

    func export(to folder: URL? = nil) async throws -> ExportReport {
        let exporter = FolderExporter(library: BooksLibrary(documents: documents), stateDirectory: state)
        return try await exporter.run(to: folder ?? destination)
    }
}
