import AppKit
import AppleBooks2FolderCore
import SwiftUI

struct SyncView: View {
    @ObservedObject var model: SyncModel
    @State private var countText = "30"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                source
                destination
                scope
                frequency
                controls
                status
                if !model.busy {
                    ForEach(BooksFolder.allCases.filter { model.foldersNeedingAccess.contains($0) }, id: \.self) { folder in
                        Button(message("授权\(folder.label)…", "Allow \(folder.label) Access…")) {
                            model.authorize(folder)
                        }
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: 690)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 530, minHeight: 440)
        .onAppear { countText = String(model.count) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("AppleBooks2Folder").font(.title.bold())
                Text(message("从 Apple Books 导出 PDF 和 EPUB", "Export PDFs and EPUBs from Apple Books"))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(message("来源", "Source")).font(.headline)
            HStack(spacing: 8) {
                Label("Apple Books", systemImage: "books.vertical")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(message("自动识别", "Auto-detect"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(message("目标文件夹", "Destination Folder")).font(.headline)
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(model.destination?.path ?? message("尚未选择文件夹", "No folder selected"))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.destination != nil {
                    Button(action: model.reveal) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help(message("在访达中打开", "Open in Finder"))
                    .accessibilityLabel(message("在访达中打开", "Open in Finder"))
                }
                Button(model.destination == nil ? message("选择文件夹…", "Choose Folder…") : message("更改…", "Change…"), action: model.choose)
                    .disabled(model.busy)
            }
            .padding(12)
            .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 10))
            Text(message("选择坚果云或其他网盘的同步目录，由网盘客户端把书籍传到其他设备。",
                         "Choose a Nutstore or other cloud sync folder. The cloud client transfers your books to other devices."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker(message("导出范围", "Export Scope"),
                       selection: Binding(get: { model.exportAll }, set: model.setExportAll)) {
                    Text(message("全部", "All Books")).tag(true)
                    Text(message("前面的", "First N Books")).tag(false)
                }
                .fixedSize()
                if !model.exportAll {
                    TextField("30", text: $countText)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(applyCount)
                        .accessibilityLabel(message("导出书籍数量", "Number of Books to Export"))
                    Text(message("本", "books"))
                    Button(message("应用", "Apply"), action: applyCount)
                        .disabled(parsedCount == nil || parsedCount == model.count)
                }
            }
            if !model.exportAll {
                Picker(message("排列顺序", "Sort Order"),
                       selection: Binding(get: { model.order }, set: model.setOrder)) {
                    ForEach(BooksShelfOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Text(parsedCount == nil ? ExportError.invalidCount.localizedDescription :
                    message("按顺序选择前 1–2,000 本 PDF 和 EPUB。缩小范围会保留已导出的文件。",
                            "Select the first 1–2,000 PDFs and EPUBs in order. Narrowing the scope keeps earlier exports."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(model.busy)
    }

    private var parsedCount: Int? {
        let digits = countText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.allSatisfy({ (0...9).contains($0.wholeNumberValue ?? -1) }),
              let count = Int(digits.compactMap(\.wholeNumberValue).map(String.init).joined()),
              ExportSelection.allowedCounts.contains(count) else { return nil }
        return count
    }

    private func applyCount() {
        guard let parsedCount else { return }
        model.setCount(parsedCount)
        countText = String(parsedCount)
    }

    private var frequency: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker(message("同步频率", "Sync Frequency"),
                   selection: Binding(get: { model.frequency }, set: model.setFrequency)) {
                ForEach(SyncFrequency.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .disabled(model.busy)
        }
    }

    private var controls: some View {
        HStack {
            Toggle(message("自动同步", "Automatic Sync"),
                   isOn: Binding(get: { model.automatic }, set: model.setAutomatic))
                .disabled(!model.automatic && (!model.ready || hasPendingCount))
            Spacer()
            Button(action: model.run) {
                Label(message("立即导出", "Export Now"), systemImage: "arrow.down.to.line")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!model.ready || model.busy || hasPendingCount)
        }
    }

    private var hasPendingCount: Bool { !model.exportAll && parsedCount != model.count }

    @ViewBuilder
    private var status: some View {
        if model.busy {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(message("正在检查书库并导出…", "Checking the library and exporting…"))
            }
        } else if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if let report = model.report {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                HStack {
                    Text(message("导出结果", "Export Results")).font(.headline)
                    Spacer()
                    if let finished = model.finished {
                        Text(finished, format: .dateTime.month().day().hour().minute())
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 9) {
                    metric(report.exported, message("新导出", "Exported"))
                    metric(report.existing, message("已存在", "Existing"))
                    metric(report.waiting, message("待下载", "Waiting"))
                    metric(report.skipped, message("已跳过", "Skipped"))
                    metric(report.failed, message("失败", "Failed"))
                }
                if !report.issues.isEmpty {
                    DisclosureGroup(message("查看待处理书籍", "Show Books That Need Attention")) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(report.issues) { issue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.title).fontWeight(.medium)
                                    Text(issue.reason).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                } else if report.exported == 0 && report.existing == 0 {
                    Text(message("书库中没有找到 PDF 或 EPUB。", "No PDFs or EPUBs were found in the library."))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func metric(_ count: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(count, format: .number).font(.title2.monospacedDigit().weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

}
