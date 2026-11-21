# 汉化分支维护说明

更新于 2026-11-21。本页记录 `fwx997/LiveContainer` 当前分支的源码结构和恢复要点；双仓库工作区的完整运维流程以工作区根目录 `AI_MANUAL.md` 为准。

## 源码与安装包状态

| 项目 | 当前记录 |
|---|---|
| LiveContainer 编译提交 | `c72c6096900b3b16bf2d00bc5710e16dc80b7a41`，分支 `codex/upstream-package-20261121` |
| 上游基线 | `b0f53e8934df325970e9b6ff52932a43b585c424`，3.8.14；以已交付 `.34` 的 `44a7149` 为基础合并 10 个提交 |
| 配套 SideStore | `07059e876671dd6be8169d261bc8311538c66abc`，分支 `codex/upstream-build-20261121`；应用逻辑与 `.34` 相同，仅调整组合构建依赖准备 |
| 组合构建 | [44894319088](https://github.com/fwx997/SideStore/actions/runs/44894319088)，LC 3.8.14 + SS `0.7.0-20261121.36+07059e87` |
| 构建与验包 | macOS 的 24 项 LC、8 项 SS、6 项打包回归通过；完整编译与本地 IPA 校验通过 |
| 当前常用交付入口 | `LiveContainer+SideStore_zh_2026-11-21.36.ipa`；常用入口与明确版本入口哈希一致 |
| 发布与设备验证 | 未发布 Release；保留 `.34`；新包真机升级、PiP 与锁屏自动续签仍待验收 |

整理文档或忽略规则产生的提交不改变安装包内的编译提交。恢复时分别核对源码 HEAD、实际 IPA 元数据和交付收据。

当前合并包为 36,001,344 字节，SHA-256 `ed7809a1aec18e1bbd9031d26a8677c1e0d400f62f41a53dac79351bc7d390ed`。工作区 `artifacts/upstream-verification-2026-11-21.json` 保存验包收据，`tools/reports/upstream-refresh-2026-11-21.md` 记录认证排查与交付边界。源码 ZIP 按实际编译提交归档，后续文档提交不改变包内版本。

## 代码入口

| 文件或目录 | 维护职责 |
|---|---|
| `LiveContainer/LCOrientationBridge.h` | 客体全屏、播放状态及媒体描述接口 |
| `TweakLoader/UIKit+GuestHooks.m` | 客体 UIKit hook、桥接调用和背景通知恢复 |
| `LiveContainerSwiftUI/MultitaskSupport/AppSceneViewController.m` | 宿主前台、客体连接与存活检查，方向和播放状态发布 |
| `LiveContainerSwiftUI/MultitaskSupport/VirtualWindowsHostView.m` | 虚拟窗口和方向请求协调 |
| `LiveContainerSwiftUI/MultitaskSupport/DecoratedAppSceneViewController.m` | 标题栏、最大化、退出时的窗口几何恢复 |
| `LiveContainerSwiftUI/MultitaskSupport/PiPManager.m` | 容器与视频 PiP 的生命周期、接管及清理 |
| `LiveContainerSwiftUI/MultitaskSupport/LCMediaPiPController.h/.m` | AVPlayerLayer 视频 PiP、系统播放控制、直播续址和过期回调隔离 |
| `LiveContainer/Info.plist` | 宿主后台 audio、媒体 ATS 例外和本地网络配置 |
| `.github/tests/` | 打包校验、方向、背景刷新、容器及视频 PiP 回归入口 |

## 合并上游时保留的约束

- 全屏 v2 由宿主核对客体连接、存活、前台和窗口状态，实际方向与宽高匹配后才回执成功；退出恢复原方向和浮窗状态。
- 每轮视频接管创建独立 `mediaLease`，只有匹配 `handoffLease` 的 ACK 才允许宿主加载播放器并激活音频。提议阶段不抢占客体声音。
- 接管后的播放意图由原生控制维持；后续普通描述不能覆盖系统暂停。直播继续时，按递增 `mediaRequest` 等待最新地址，超时或失败保持暂停。
- 停止、客体终止、连接失效和过期 session/lease 必须撤销许可；旧 KVO、seek 和就绪回调不能恢复已停止的播放。
- 新控制器属于 `LiveContainerSwiftUI` 目标。宿主保留 `NSAllowsArbitraryLoadsForMedia`、`NSAllowsLocalNetworking` 与后台 `audio`，并在实际 IPA 中再次核对。
- 客体需要实现媒体状态和接管协议。不能将容器 PiP 窗口正常显示等同于任意应用的视频持续播放已通过。

## 验证入口

在本仓库根目录运行已有回归：

```powershell
python -X utf8 -B -m unittest discover -s .github/tests -v
```

Windows 可执行打包和源码拼接检查；依赖 macOS Foundation、clang 或 Swift 的原生行为测试会明确跳过。本轮组合构建启用了原生回归，原有纯打包选项仍可供明确需要时使用。原生回归不能替代 iPhone/iPad 真机验收。

上游已将 `MultitaskSupport` 移入 `LiveContainerSwiftUI`，测试、桥接头和自有 PiP 文件必须使用新路径。OpenSSL 改由 `.github/prepare_dependencies.sh` 下载固定版本，组合流程需在归档前调用。受现有凭据权限限制，打包分支保留旧的独立 `build.yml`，应使用 SideStore 的 `package-livecontainer.yml`（Xcode 27.2）；本地 `codex/upstream-refresh-20261121` 分支保留上游独立工作流改动。

真机仍需确认 HTTP/localhost 取流、暂停后返回最新直播、反复进出 PiP 与横屏恢复、首次暂停时首帧及长时间续址。

## 双仓库工作区与备份

本轮合并源码位于 `LC-upstream-20261121/` 和 `SS-upstream-20261121/` 两个独立 worktree。原 `LC-src/` 的 16 项未提交修改及 `SideStore-src/` 保留原状态；不要把它们的旧 HEAD 当作本轮编译来源。完整工作区还包含 `tools/`、`AI_MANUAL.md` 和 `build_check.bat`。以下命令在工作区根目录运行，脚本不属于单独的 LiveContainer 上游克隆：

```powershell
python -X utf8 -B tools/sync_backup.py
```

源码快照位于同级 `backup/lc+ss/`，包含两个源码树、维护工具和文档；排除 Git 历史、交付与下载包、参考克隆及 Python 缓存。已跟踪的源码资源（如 SideStore 的 `SideBackup.ipa` 占位文件）随源码保留。个人资料目录不参与同步。

该脚本仍同步原两个源码目录。本轮新合并的实际编译源码另存 `artifacts/LiveContainer-upstream-20261121-source.zip` 与 `artifacts/SideStore-upstream-build-20261121-source.zip`，并复制到备份目录的 `upstream-20261121/`。恢复本轮代码时使用这些归档或上述 fork 分支。

镜像同步会移除备份中已从工作区删除的文件，整理前应按清单保留可恢复副本。完成后逐文件核对相对路径、大小和 SHA-256，保留整理与校验收据。

2026-11-11 的整理清单为工作区 `tools/reports/workspace-cleanup-2026-11-11.json`，备份校验收据为 `tools/reports/backup-verification-2026-11-11.json`。已核对一致的 `.30` 重复下载包和 Python 缓存送入回收站，正式交付包、源码 ZIP、下载摘要及原始验包记录继续保留。重放下载目录的验包步骤前，需重新下载构建附件。

恢复时先在空目录克隆两个个人 fork，再覆盖快照内容并保留克隆生成的 `.git`；核对快照记录的分支、提交及子模块版本。构建凭据在本机配置，勿提交到 GitHub。安装包与源码快照分开保管，当前本地交付与公开 Release 分别核对。
