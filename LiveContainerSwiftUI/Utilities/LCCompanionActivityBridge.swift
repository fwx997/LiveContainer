import Foundation

@MainActor
@objc(LCCompanionActivityBridge)
final class LCCompanionActivityBridge: NSObject {
    @objc static func switchBlockReason() -> String? {
        let model = DataManager.shared.model
        let apps = model.apps + model.hiddenApps + model.arm32EmuApps
        if apps.contains(where: { $0.isSigningInProgress || $0.isAppRunning }) {
            return "正在启动或签名应用，请完成后再切换。"
        }
        if model.isJITModalOpen { return "请先完成或关闭 JIT 操作。" }
        if MultitaskManager.isMultitasking() { return "请先关闭正在运行的多任务窗口，再切换应用。" }
        return nil
    }
}
