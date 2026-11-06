import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

func fingerprint(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct FileStamp {
    let attributes: stat
    var size: Int64 { attributes.st_size }
    var isFile: Bool { attributes.st_mode & S_IFMT == S_IFREG }
    var isDirectory: Bool { attributes.st_mode & S_IFMT == S_IFDIR }
    var isDataless: Bool { attributes.st_flags & UInt32(SF_DATALESS) != 0 }
    var token: String {
        let a = attributes
        return "\(a.st_dev):\(a.st_ino):\(a.st_size):\(a.st_mtimespec.tv_sec):\(a.st_mtimespec.tv_nsec):\(a.st_ctimespec.tv_sec):\(a.st_ctimespec.tv_nsec)"
    }

    init(_ url: URL) throws {
        var attributes = stat()
        if lstat(url.path, &attributes) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.attributes = attributes
    }
}

struct Original {
    let url: URL
    let stamp: FileStamp
    let members: [(path: String, url: URL, stamp: FileStamp)]
    let signature: String
    var ext: String { url.pathExtension.lowercased() }

    init(_ url: URL) throws {
        let stamp: FileStamp
        do { stamp = try FileStamp(url) }
        catch let error as POSIXError where error.code == .ENOENT { throw ExportError.notDownloaded }
        catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
            throw ExportError.originalAccessDenied
        }
        guard !stamp.isDataless else { throw ExportError.notDownloaded }
        self.url = url
        self.stamp = stamp

        if stamp.isFile {
            members = []
            signature = stamp.token
            return
        }
        guard stamp.isDirectory, url.pathExtension.lowercased() == "epub" else { throw ExportError.invalidBook }
        // The directory enumerator returns physical paths, including /private/var for /var.
        guard let resolved = realpath(url.path, nil) else { throw ExportError.changed }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        guard try FileStamp(root).token == stamp.token else { throw ExportError.changed }
        var walkError: Error?
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, error in walkError = error; return false }) else { throw ExportError.invalidBook }
        let prefix = root.path + "/"
        var members: [(path: String, url: URL, stamp: FileStamp)] = []
        for case let member as URL in walker {
            guard member.path.hasPrefix(prefix) else { throw ExportError.invalidBook }
            let path = String(member.path.dropFirst(prefix.count))
            if member.lastPathComponent.hasSuffix(".icloud") { throw ExportError.notDownloaded }
            let file = try FileStamp(member)
            guard !file.isDataless else { throw ExportError.notDownloaded }
            if file.isDirectory { continue }
            guard file.isFile else { throw ExportError.invalidBook }
            if path == "mimetype" || member.lastPathComponent == ".DS_Store" || member.lastPathComponent.hasPrefix("._") {
                continue
            }
            members.append((path, member, file))
        }
        if let walkError { throw walkError }
        guard members.contains(where: { $0.path == "META-INF/container.xml" }) else { throw ExportError.notDownloaded }
        self.members = members.sorted { $0.path < $1.path }
        signature = fingerprint(stamp.token + self.members.map { "\($0.path.utf8.count):\($0.path):\($0.stamp.token)" }.joined(separator: "\n"))
    }

    func stage(at destination: URL) throws {
        if stamp.isFile {
            try copyBytes(from: url, to: destination)
        } else {
            try package(at: destination)
        }
        guard try Self(url).signature == signature else { throw ExportError.changed }
        if ext == "pdf" {
            guard let document = CGPDFDocument(destination as CFURL) else { throw ExportError.invalidBook }
            guard !document.isEncrypted else { throw ExportError.encrypted }
            guard document.numberOfPages > 0 else { throw ExportError.invalidBook }
        } else {
            try EPUB.validate(destination)
        }
    }

    private func package(at destination: URL) throws {
        let archive = try Archive(url: destination, accessMode: .create)
        let date = Date(timeIntervalSince1970: 946684800)
        let mime = EPUB.mime
        try archive.addEntry(with: "mimetype", type: .file, uncompressedSize: Int64(mime.count),
                             modificationDate: date, permissions: 0o644) { offset, count in
            let start = Int(offset)
            return mime.subdata(in: start..<(start + count))
        }
        for member in members {
            let handle = try FileHandle(forReadingFrom: member.url)
            defer { try? handle.close() }
            try archive.addEntry(with: member.path, type: .file, uncompressedSize: member.stamp.size,
                                 modificationDate: date, permissions: 0o644, compressionMethod: .deflate) { offset, count in
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: count) ?? Data()
                guard data.count == count else { throw ExportError.changed }
                return data
            }
        }
    }
}

func copyBytes(from source: URL, to destination: URL) throws {
    if copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)) != 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private enum EPUB {
    static let mime = Data("application/epub+zip".utf8)

    static func validate(_ url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        var entries: [String: Entry] = [:]
        for entry in archive {
            let path = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !entry.path.hasPrefix("/"), !path.isEmpty, !path.contains("\\"),
                  !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  entry.type != .symlink, entries.updateValue(entry, forKey: path) == nil else {
                throw ExportError.invalidBook
            }
        }
        guard archive.declaredEntryCount == entries.count else { throw ExportError.invalidBook }
        if entries.keys.contains(where: {
            let name = $0.lowercased()
            return name == "meta-inf/rights.xml" || (name.hasPrefix("meta-inf/") && (name.hasSuffix(".sinf") || name.hasSuffix("/sinf.xml")))
        }) { throw ExportError.encrypted }
        if let entry = entries["META-INF/encryption.xml"] {
            try checkEncryption(xml(entry, in: archive))
        }
        guard let mimeEntry = entries["mimetype"], try read(mimeEntry, in: archive, limit: mime.count) == mime,
              let container = entries["META-INF/container.xml"] else { throw ExportError.invalidBook }
        let document = try xml(container, in: archive)
        let roots = try document.nodes(forXPath: "/*[local-name()='container']/*[local-name()='rootfiles']/*[local-name()='rootfile']")
        guard let root = roots.first as? XMLElement,
              let path = root.attribute(forName: "full-path")?.stringValue,
              let package = entries[path] ?? path.removingPercentEncoding.flatMap({ entries[$0] }),
              package.type == .file else { throw ExportError.invalidBook }
    }

    private static func checkEncryption(_ document: XMLDocument) throws {
        let encrypted = try document.nodes(forXPath: "//*[local-name()='EncryptedData']")
        guard !encrypted.isEmpty else { throw ExportError.encrypted }
        let fontAlgorithms = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        let fontExtensions = ["otf", "ttf", "woff", "woff2", "ttc"]
        for node in encrypted {
            let algorithm = try node.nodes(forXPath: "./*[local-name()='EncryptionMethod']/@Algorithm")
            let resource = try node.nodes(forXPath: "./*[local-name()='CipherData']/*[local-name()='CipherReference']/@URI")
            guard algorithm.count == 1, let value = algorithm.first?.stringValue, fontAlgorithms.contains(value),
                  resource.count == 1, let path = resource.first?.stringValue?.removingPercentEncoding,
                  fontExtensions.contains((path as NSString).pathExtension.lowercased()) else { throw ExportError.encrypted }
        }
    }

    private static func xml(_ entry: Entry, in archive: Archive) throws -> XMLDocument {
        try XMLDocument(data: read(entry, in: archive, limit: 1024 * 1024), options: .nodeLoadExternalEntitiesNever)
    }

    private static func read(_ entry: Entry, in archive: Archive, limit: Int) throws -> Data {
        guard entry.type == .file, entry.uncompressedSize <= limit else { throw ExportError.invalidBook }
        var result = Data()
        let checksum = try archive.extract(entry) { data in
            guard result.count + data.count <= limit else { throw ExportError.invalidBook }
            result.append(data)
        }
        guard checksum == entry.checksum, result.count == entry.uncompressedSize else { throw ExportError.invalidBook }
        return result
    }
}
