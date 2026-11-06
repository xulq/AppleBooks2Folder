import Foundation

struct ScopedFolder {
    let url: URL
    let bookmark: Data

    init(selected url: URL, readOnly: Bool = false) throws {
        try self.init(bookmark: Self.makeBookmark(for: url, readOnly: readOnly), readOnly: readOnly)
    }

    private init(bookmark: Data, readOnly: Bool) throws {
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            guard resolved.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            defer { resolved.stopAccessingSecurityScopedResource() }
            self.bookmark = try Self.makeBookmark(for: resolved, readOnly: readOnly)
        } else {
            self.bookmark = bookmark
        }
        url = resolved
    }

    static func restore(key: String, readOnly: Bool = false) -> ScopedFolder? {
        let defaults = UserDefaults.standard
        guard let bookmark = defaults.data(forKey: key),
              let folder = try? Self(bookmark: bookmark, readOnly: readOnly) else { return nil }
        if folder.bookmark != bookmark { defaults.set(folder.bookmark, forKey: key) }
        return folder
    }

    private static func makeBookmark(for url: URL, readOnly: Bool) throws -> Data {
        let options: URL.BookmarkCreationOptions = readOnly ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : .withSecurityScope
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
