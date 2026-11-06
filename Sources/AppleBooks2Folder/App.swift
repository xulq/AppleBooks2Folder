import AppKit
import AppleBooks2FolderCore
import SwiftUI

@main
struct AppleBooks2FolderApp: App {
    @StateObject private var model = SyncModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("AppleBooks2Folder", id: "library") {
            SyncView(model: model)
        }
        .defaultSize(width: 575, height: 650)
        .windowResizability(.contentMinSize)

        MenuBarExtra("AppleBooks2Folder", systemImage: "books.vertical") {
            Button(message("显示主窗口", "Show Window")) {
                openWindow(id: "library")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(message("立即导出", "Export Now"), action: model.run)
                .disabled(!model.ready || model.busy)
            Button(model.automatic ? message("暂停自动同步", "Pause Automatic Sync") :
                                     message("开启自动同步", "Enable Automatic Sync")) {
                model.setAutomatic(!model.automatic)
            }
            .disabled(!model.ready && !model.automatic)
            Button(message("打开目标文件夹", "Open Destination"), action: model.reveal)
                .disabled(model.destination == nil)
            Divider()
            Button(message("退出 AppleBooks2Folder", "Quit AppleBooks2Folder")) { NSApp.terminate(nil) }
                .disabled(model.busy)
        }
    }
}

