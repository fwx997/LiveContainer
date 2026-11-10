# 汉化分支维护说明

更新于 2026-11-11。本页记录 `fwx997/LiveContainer` 当前分支的源码结构和恢复要点；双仓库工作区的完整运维流程以工作区根目录 `AI_MANUAL.md` 为准。

## 源码与安装包状态

| 项目 | 当前记录 |
|---|---|
| LiveContainer 功能提交 | `04ca08c9c9ef089b0b45b213ba654ec62c748596`，分支 `codex/media-pip-20261110` |
| 配套 SideStore | `a23d8703abf3474bdb504b71da65a1de860a193c`，分支 `codex/package-only-20261109` |
| 视频画中画构建 | [42799074298](https://github.com/fwx997/SideStore/actions/runs/42799074298)，LC 3.8.12 + SS `0.7.0-20261110.30+a23d8703` |
| 构建与验包 | 编译打包成功；已有本地 IPA 结构、版本、桥接标记及宿主媒体配置校验记录 |
| 当前常用交付入口 | 已更新为 `.30`：LC `04ca08c` + SS `0.7.0-20261110.30+a23d8703`；常用入口与明确版本入口哈希一致 |
| 配套墨舟 | `2.4.50+261111001`，已完成两端独立验包及本地配套交付 |
| 发布与设备验证 | 此构建未发布 Release；云端仅编译打包，原生行为回归及真机效果待验证 |

整理文档或忽略规则产生的提交不改变安装包内的编译提交。恢复时分别核对源码 HEAD、实际 IPA 元数据和交付收据。

当前合并包为 35,731,251 字节，SHA-256 `f9e618cf096e41ee8795ebdae7d075c1e793b9ef543d158e9b7ca62502cb9232`。工作区 `artifacts/media-pip-verification-2026-11-10.json` 和 `artifacts/paired-media-delivery-2026-11-11.json` 保存验包与配套交付记录；`.29` 明确版本包继续保留。

## 代码入口

| 文件或目录 | 维护职责 |
|---|---|
| `LiveContainer/LCOrientationBridge.h` | 客体全屏、播放状态及媒体描述接口 |
| `TweakLoader/UIKit+GuestHooks.m` | 客体 UIKit hook、桥接调用和背景通知恢复 |
| `MultitaskSupport/AppSceneViewController.m` | 宿主前台、客体连接与存活检查，方向和播放状态发布 |
| `MultitaskSupport/VirtualWindowsHostView.m` | 虚拟窗口和方向请求协调 |
| `MultitaskSupport/DecoratedAppSceneViewController.m` | 标题栏、最大化、退出时的窗口几何恢复 |
| `MultitaskSupport/PiPManager.m` | 容器与视频 PiP 的生命周期、接管及清理 |
| `MultitaskSupport/LCMediaPiPController.h/.m` | AVPlayerLayer 视频 PiP、系统播放控制、直播续址和过期回调隔离 |
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

Windows 可执行打包和源码拼接检查；依赖 macOS Foundation、clang 或 Swift 的原生行为测试会明确跳过。视频画中画的纯打包构建跳过云端回归，其成功不代表原生 harness 或 iPhone 验收通过。

真机仍需确认 HTTP/localhost 取流、暂停后返回最新直播、反复进出 PiP 与横屏恢复、首次暂停时首帧及长时间续址。

## 双仓库工作区与备份

完整工作区由并列的 `LC-src/`、`SideStore-src/`、`tools/`、`AI_MANUAL.md` 和 `build_check.bat` 组成。以下命令在该工作区根目录运行，脚本不属于单独的 LiveContainer 上游克隆：

```powershell
python -X utf8 -B tools/sync_backup.py
```

源码快照位于同级 `backup/lc+ss/`，包含两个源码树、维护工具和文档；排除 Git 历史、交付与下载包、参考克隆及 Python 缓存。已跟踪的源码资源（如 SideStore 的 `SideBackup.ipa` 占位文件）随源码保留。个人资料目录不参与同步。

镜像同步会移除备份中已从工作区删除的文件，整理前应按清单保留可恢复副本。完成后逐文件核对相对路径、大小和 SHA-256，保留整理与校验收据。

2026-11-11 的整理清单为工作区 `tools/reports/workspace-cleanup-2026-11-11.json`，备份校验收据为 `tools/reports/backup-verification-2026-11-11.json`。已核对一致的 `.30` 重复下载包和 Python 缓存送入回收站，正式交付包、源码 ZIP、下载摘要及原始验包记录继续保留。重放下载目录的验包步骤前，需重新下载构建附件。

恢复时先在空目录克隆两个个人 fork，再覆盖快照内容并保留克隆生成的 `.git`；核对快照记录的分支、提交及子模块版本。构建凭据在本机配置，勿提交到 GitHub。安装包与源码快照分开保管，当前本地交付与公开 Release 分别核对。
