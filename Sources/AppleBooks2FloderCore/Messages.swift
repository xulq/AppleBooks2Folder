import Foundation

private let usesSimplifiedChinese = Bundle.main.preferredLocalizations.first == "zh-Hans"

public func message(_ chinese: String, _ english: String) -> String {
    usesSimplifiedChinese ? chinese : english
}

public enum ExportError: LocalizedError {
    case noLibrary, permission, ambiguousLibrary, invalidLibrary, protectedFolder, destination
    case sortUnavailable, invalidCount, notDownloaded, encrypted, invalidBook, changed, collision
    case originalPermission, originalAccessDenied

    public var errorDescription: String? {
        switch self {
        case .noLibrary:
            return message("找不到 Apple Books 书库。请在 Mac 上打开「图书」，下载至少一本书后重试。",
                           "No Apple Books library was found. Open Books on this Mac, download a book, then retry.")
        case .permission:
            return message("macOS 拒绝了资料库读取。点击下方按钮，按面板提示授权「图书」文件夹。",
                           "macOS denied access to the Books library. Open the access panel below and follow the instructions.")
        case .originalPermission:
            return message("原件不在应用可读取的 Apple Books 文件夹内。请在「图书」中下载本地副本后重试。",
                           "The original is outside the supported Apple Books folders. Download a local copy in Books and try again.")
        case .originalAccessDenied:
            return message("macOS 拒绝了原件读取。可以在导出结果中授权对应的图书文件夹。",
                           "macOS denied access to the original. You can grant access to its Books folder from Export Results.")
        case .ambiguousLibrary:
            return message("找到多个 Apple Books 书库，无法确定当前书库。", "Multiple Apple Books libraries were found.")
        case .invalidLibrary:
            return message("无法读取当前书库格式，或书库正忙。请稍后重试。", "The library format is unsupported or the library is busy. Try again shortly.")
        case .sortUnavailable:
            return message("无法识别「图书」的排列顺序。请在「排列顺序」中选用与「图书」相同的选项。",
                           "The Books sort order could not be determined. Select the matching sort order here.")
        case .invalidCount:
            return message("请输入 1 到 2,000 本。", "Enter a count from 1 to 2,000.")
        case .protectedFolder:
            return message("请选择 Apple Books 资料库之外的文件夹。", "Choose a folder outside the Apple Books library.")
        case .destination:
            return message("目标文件夹不可用。请检查网盘客户端，再重新选择文件夹。",
                           "The destination folder is unavailable. Check your cloud client and choose the folder again.")
        case .notDownloaded:
            return message("原件尚未下载，请在「图书」中下载后重试。", "Download the original in Apple Books and retry.")
        case .encrypted:
            return message("原件受 DRM 或加密保护，已跳过。", "Skipped because the original is encrypted or DRM-protected.")
        case .invalidBook:
            return message("文件格式不完整、不受支持或包含链接。", "The file is incomplete, unsupported, or contains links.")
        case .changed:
            return message("原件在导出期间发生变化，下次会重试。", "The original changed during export and will be retried.")
        case .collision:
            return message("同名文件过多，无法为这本书分配文件名。", "Too many filename conflicts for this book.")
        }
    }
}
