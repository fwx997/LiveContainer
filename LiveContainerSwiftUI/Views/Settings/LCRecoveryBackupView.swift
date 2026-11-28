import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class LCRecoveryBackupModel: ObservableObject {
    @Published var state: [String: Any] = [:]
    @Published var working = false
    @Published var message: String?

    var configured: Bool { state["configured"] as? Bool ?? false }
    var automatic: Bool { state["automatic"] as? Bool ?? false }
    var directory: String { text("directoryName", fallback: "未选择") }
    var cachedBuild: String { text("cacheBuild", fallback: LCSharedUtils.hostAppBundle().object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—") }
    var exportedBuild: String { text("exportBuild", fallback: "尚未保存") }

    private func text(_ key: String, fallback: String) -> String {
        guard let value = state[key] as? String, !value.isEmpty else { return fallback }
        return value
    }

    func reload() { state = LCRecoveryBackup.status() }

    func changeAutomatic(_ enabled: Bool) {
        LCRecoveryBackup.setAutomatic(enabled)
        reload()
    }

    func select(_ directory: URL) {
        let scoped = directory.startAccessingSecurityScopedResource()
        working = true
        message = nil
        Task {
            let failure = await Task.detached(priority: .utility) { () -> String? in
                defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
                do { try LCRecoveryBackup.configureDirectory(directory); return nil }
                catch { return error.localizedDescription }
            }.value
            working = false
            message = failure
            reload()
        }
    }

    func save() {
        working = true
        message = nil
        LCRecoveryBackup.saveWithCompletion { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.working = false
                self.reload()
                self.message = error?.localizedDescription ?? "已保存 \(self.exportedBuild)"
            }
        }
    }
}

struct LCRecoveryBackupView: View {
    @StateObject private var model = LCRecoveryBackupModel()
    @State private var selectingDirectory = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                valueRow("本机安装包", value: model.cachedBuild)
                valueRow("已备份版本", value: model.exportedBuild)
            } header: { Text("安装包") }
            Section {
                Button { selectingDirectory = true } label: {
                    HStack {
                        Text("保存位置")
                        Spacer()
                        Text(model.directory).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    }
                }
                Toggle("更新后自动保存", isOn: Binding(get: { model.automatic }, set: model.changeAutomatic))
                    .disabled(!model.configured)
                Button { model.save() } label: {
                    HStack {
                        Text(model.working ? "正在保存…" : "立即保存")
                        if model.working { Spacer(); ProgressView() }
                    }
                }
                .disabled(!model.configured || model.working)
            } header: { Text("保存") } footer: {
                Text("保存安装包和本地安装脚本。复用本机文件，无需重新下载。")
            }
            .disabled(model.working)
            Section {
                Button("打开 Open Minis") { openMinis() }
                NavigationLink("首次设置与使用说明") { LCRecoveryInstructionsView() }
            } header: { Text("重新安装") } footer: {
                Text("首次使用需将保存文件夹挂载到 Open Minis。")
            }
            if let message = model.message ?? model.state["error"] as? String, !message.isEmpty {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("本地恢复备份")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.reload() }
        .onChange(of: scenePhase) { phase in if phase == .active { model.reload() } }
        .sheet(isPresented: $selectingDirectory) {
            LCRecoveryDirectoryPicker { directory in
                selectingDirectory = false
                if let directory { model.select(directory) }
            }
        }
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func openMinis() {
        var components = URLComponents()
        components.scheme = "minis"
        components.host = "open_terminal"
        components.queryItems = [URLQueryItem(name: "init_command", value: "sh /var/minis/mounts/livecontainer/install-local.sh")]
        guard let url = components.url else { return }
        UIApplication.shared.open(url) { opened in
            if !opened { Task { @MainActor in model.message = "请先安装并打开 Open Minis。" } }
        }
    }
}

private struct LCRecoveryDirectoryPicker: UIViewControllerRepresentable {
    let completion: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
    }
}

private struct LCRecoveryInstructionsView: View {
    private let installCommand = "sh /var/minis/mounts/livecontainer/install-local.sh"

    var body: some View {
        Form {
            Section("首次设置") {
                Text("选择本机可长期保留的文件夹。恢复文件统一保存在其中的 livecontainer 文件夹；也可以直接选择已有的 livecontainer。")
                Text("在 Open Minis 的“挂载文件夹”中选择同一个 livecontainer 文件夹，挂载名称也填 livecontainer。随后返回终端。")
                Text("Minis 1.16 的独立终端与系统“文件”中的默认 shared 可能是不同目录，请使用这个明确挂载的位置。")
                Button("打开 Minis 挂载设置") {
                    UIApplication.shared.open(URL(string: "minis://settings/mount-external")!)
                }
            }
            Section("本地重新安装") {
                Text(installCommand).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button("复制安装命令") { UIPasteboard.general.string = installCommand }
                Text("运行前先连接 LocalDevVPN。安装包从本地读取；Apple 登录和签名仍可能需要联网。")
            }
            Section("更换位置与自动保存") {
                Text("保存位置随时可以更换。自动保存与“立即保存”共用同一位置；换位置后，在 Minis 中重新选择这个文件夹。")
                Text("自动保存会在验证更新包后、系统替换正在运行的 Live 之前完成，避免更新后 Live 无法打开时没有恢复包。")
                Text("如果终端提示文件不存在，回到 Minis 的挂载设置重新启用该文件夹。不要在未挂载的位置手动创建同名空目录。")
            }
        }
        .navigationTitle("使用说明")
        .navigationBarTitleDisplayMode(.inline)
    }
}
