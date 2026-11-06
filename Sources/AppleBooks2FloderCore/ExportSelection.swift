import Foundation

public enum ExportSelection: Equatable, Sendable {
    public static let allowedCounts = 1...2000
    case all
    case first(Int, order: BooksShelfOrder)
}

public enum BooksShelfOrder: String, CaseIterable, Sendable {
    case automatic, recent, title, author, manual

    public var label: String {
        switch self {
        case .automatic: return message("跟随「图书」", "Follow Books")
        case .recent: return message("最近", "Recent")
        case .title: return message("书名", "Title")
        case .author: return message("作者", "Author")
        case .manual: return message("手动顺序", "Manual Order")
        }
    }

    // BookAlong Sync's decoding of the Books “All” collection.
    init?(booksMode: String?) {
        switch booksMode?.lowercased() {
        case "1", "2", "7", "recent", "recency", "recentlyread", "mostrecent": self = .recent
        case "3", "title", "sorttitle": self = .title
        case "4", "author", "sortauthor": self = .author
        case "0", "6", "manual", "manually", "sortkey": self = .manual
        default: return nil
        }
    }
}
