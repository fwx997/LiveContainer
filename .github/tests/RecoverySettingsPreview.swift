import SwiftUI
import UIKit

struct RecoverySettingsPreview: View {
    @State private var automatic = true
    @State private var saved = false
    private let detail = ProcessInfo.processInfo.arguments.contains("single")

    var body: some View {
        NavigationStack {
            if detail {
                recoveryForm
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {} label: { Image(systemName: "chevron.left") }
                        }
                    }
            } else {
                settingsForm
            }
        }
        .tint(.blue)
    }

    private var settingsForm: some View {
        Form {
            Section {
                Toggle("动态主题色", isOn: .constant(true))
                Toggle("深色 App 图标", isOn: .constant(true))
            } header: { Text("界面") }
            Section {
                Toggle("切换 App 时不询问", isOn: .constant(false))
            }
            Section {
                Button("清除通知") {}
            }
            Section {
                NavigationLink("存储管理") { Text("存储管理") }
                NavigationLink("数据管理") { Text("数据管理") }
                NavigationLink("本地恢复备份") { recoveryForm }
            }
            Section {
                Link("LiveContainer/LiveContainer", destination: URL(string: "https://github.com/LiveContainer/LiveContainer")!)
                Link("khanhduytran0", destination: URL(string: "https://github.com/khanhduytran0")!)
                Link("Huge_Black", destination: URL(string: "https://github.com/hugeBlack")!)
            } header: { Text("关于") }
        }
        .navigationTitle("设置")
    }

    private var recoveryForm: some View {
        Form {
            Section {
                LabeledContent("本机安装包", value: "20261128.81")
                LabeledContent("已备份版本", value: saved ? "20261128.81" : "20261128.80")
            } header: { Text("安装包") }
            Section {
                Button {} label: {
                    HStack {
                        Text("保存位置").foregroundStyle(.primary)
                        Spacer()
                        Text("livecontainer").foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                Toggle("更新后自动保存", isOn: $automatic)
                Button(saved ? "再次保存" : "立即保存") { saved = true }
            } header: { Text("保存") } footer: {
                Text("保存安装包和本地安装脚本。复用本机文件，无需重新下载。")
            }
            Section {
                Button("打开 Open Minis") {}
                NavigationLink("首次设置与使用说明") {
                    Form {
                        Text("在 Open Minis 的挂载文件夹中选择同一个保存位置，命名为 livecontainer。")
                        Text("默认 shared 可能与独立终端不是同一目录，请使用明确挂载的恢复目录。")
                    }.navigationTitle("使用说明").navigationBarTitleDisplayMode(.inline)
                }
            } header: { Text("重新安装") } footer: {
                Text("首次使用需将保存文件夹挂载到 Open Minis。")
            }
            if saved {
                Section {
                    Label("已保存 20261128.81", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("本地恢复备份")
        .navigationBarTitleDisplayMode(.inline)
    }
}

final class PreviewDelegate: NSObject, UIApplicationDelegate, UIWindowSceneDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RecoverySettingsPreview())
        window.overrideUserInterfaceStyle = ProcessInfo.processInfo.arguments.contains("dark") ? .dark : .light
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? "ready".write(to: documents.appendingPathComponent("ready.txt"), atomically: true, encoding: .utf8)
        }
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(PreviewDelegate.self))
