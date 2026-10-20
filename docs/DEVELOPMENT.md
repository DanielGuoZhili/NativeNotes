# 开发说明

## 技术与目录

Swift Package（Swift tools 5.9），macOS 14+，无第三方依赖。

| 文件 | 职责 |
| --- | --- |
| `NativeNotes.swift` | 应用入口、来源工作区、Core Data 缓存 |
| `NotesBridge.swift` | 只读 AppleScript 访问及错误映射 |
| `SourceBrowser.swift` / `SourceFilter.swift` | 来源列表、搜索与筛选 |
| `WorkspaceSplitView.swift` | NSSplitViewController 三栏布局 |
| `EditorCore.swift` | 本地文档模型、JSON 持久化、撤销、列表与表格操作 |
| `LocalEditorView.swift` | 本地块编辑器、待办与表格界面 |
| `EditorTextInput.swift` | AppKit NSTextView、输入法与高度测量缓存 |
| `RichFormatting.swift` | RTF 编解码、选区格式工具 |
| `NativeDragHandle.swift` | 待办行尾拖动、显示刷新同步 |
| `RichNoteView.swift` | 只读来源 HTML 预览 |
| `SelfTest.swift` / `EditorChecks.swift` | 隔离回归检查 |
| `Resources/` | Info.plist、自动化 entitlement、图标 |

缓存使用 Core Data，不是 SwiftData；本地编辑采用独立 JSON 文档。

## 常用命令

```sh
./verify.sh
./build.sh
open dist/NativeNotes.app
open dist/NativeNotes.app --args --demo
```

`NATIVENOTES_BUILD_DIR` 可覆盖构建目录；`NATIVENOTES_APP_PATH` 可覆盖应用输出路径。路径允许包含空格。直接运行裸 Swift 可执行文件不等同于从 Finder 启动打包应用，自动化权限身份可能不同。

构建脚本原子替换可执行文件，避免覆盖运行中已映射的二进制；复制 Info.plist 和图标后进行 ad-hoc 签名并校验。不要变更现有 bundle identifier，除非有意更换应用身份及重新授权。

## 数据兼容性

- 旧文档没有 RTF 字段时，按纯文本加载。
- 源快照和本地编辑独立；刷新不覆盖编辑。
- 损坏、未知版本或多窗口冲突时不静默覆盖。
- 兼容早期试用文档：标题恰为“任务列表”且尚无 taskPresentation 标记时，执行一次待办迁移，清理重复标题/空行，保留已有状态。此规则不是通用的原始待办识别；后续应改为显式用户选择，并覆盖旧文档迁移测试。

## 性能与回归

拖动开始时冻结布局，拖动期间保持文档原顺序，用各行位移预览；鼠标释放才提交顺序和持久化。不可将变换后的几何值重新反馈到位移计算。每帧只更新活动行，跨位置才计算让位。

三栏纯尺寸变化不重复替换 hosting root；文字高度使用独立测量和有限缓存，避免每次布局改动实时 NSTextView。保留中文输入法 marked text 保护以及无穷/空矩形检查。

修改后运行隔离检查；涉及交互时另按手动验收清单测试。模型计算耗时不等于显示 FPS。

## 提交范围

提交源码、资源和说明；不提交构建产物、用户缓存、真实笔记、个人截图、凭证或本地演示编辑文件。图标原图及 icns 可纳入版本管理。
