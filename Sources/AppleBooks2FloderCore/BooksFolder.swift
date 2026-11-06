import Darwin
import Foundation

public enum BooksFolder: String, CaseIterable, Sendable {
    case library, iCloud, legacy

    // The sandbox's home directory belongs to this app, not the logged-in user.
    static let userHome: URL = {
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: max(4096, sysconf(_SC_GETPW_R_SIZE_MAX)))
        return buffer.withUnsafeMutableBufferPointer { storage in
            if getpwuid_r(getuid(), &account, storage.baseAddress, storage.count, &result) == 0,
               result != nil, let path = account.pw_dir, path.pointee != 0 {
                return URL(fileURLWithPath: String(cString: path), isDirectory: true)
            }
            return FileManager.default.homeDirectory(forUser: NSUserName()) ?? FileManager.default.homeDirectoryForCurrentUser
        }
    }()

    func url(in home: URL) -> URL {
        let path: String
        switch self {
        case .library: path = "Library/Containers/com.apple.iBooksX/Data/Documents"
        case .iCloud: path = "Library/Mobile Documents/iCloud~com~apple~iBooks/Documents"
        case .legacy: path = "Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books"
        }
        return home.appendingPathComponent(path, isDirectory: true)
    }

    public var url: URL { url(in: Self.userHome) }

    public func acceptsAuthorizationFolder(_ candidate: URL) -> Bool {
        guard candidate.isFileURL, candidate.host == nil || candidate.host == "" || candidate.host == "localhost" else {
            return false
        }
        let expected = url.standardizedFileURL.path
        let actual = candidate.standardizedFileURL.path
        // Finder can return the data volume spelling of a path under /Users.
        return actual == expected || (expected.hasPrefix("/Users/") && actual == "/System/Volumes/Data" + expected)
    }

    public var label: String {
        switch self {
        case .library: return message("图书资料库", "Books Library")
        case .iCloud: return message("iCloud 图书", "iCloud Books")
        case .legacy: return message("旧版图书", "Legacy Books")
        }
    }

    static func containing(_ file: URL) -> BooksFolder? {
        let path = file.standardizedFileURL.pathComponents
        return allCases.first { path.starts(with: $0.url.standardizedFileURL.pathComponents) }
    }

    public static func allowsDestination(_ folder: URL) -> Bool {
        guard folder.isFileURL else { return false }
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let protectedRoots = [
            userHome.appendingPathComponent("Library/Containers/com.apple.iBooksX"),
            userHome.appendingPathComponent("Library/Mobile Documents/iCloud~com~apple~iBooks"),
            userHome.appendingPathComponent("Library/Containers/com.apple.BKAgentService")
        ]
        return !protectedRoots.contains { root in
            path.starts(with: root.pathComponents) || root.pathComponents.starts(with: path)
        } && !path.contains { $0.lowercased().hasSuffix(".epub") }
    }
}
