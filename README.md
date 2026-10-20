# NativeNotes

<p align="center"><img src="Resources/AppIcon.png" width="128" alt="NativeNotes 暖橙便笺图标"></p>

[![macOS validation](https://github.com/DanielGuoZhili/NativeNotes/actions/workflows/macos.yml/badge.svg)](https://github.com/DanielGuoZhili/NativeNotes/actions/workflows/macos.yml)

**A native macOS notes workspace with selective Apple Notes import, local rich-text editing, draggable checklists, and editable tables. Built with SwiftUI and AppKit, without third-party runtime dependencies.**

作者：[DanielGuoZhili](https://github.com/DanielGuoZhili) · [English overview](docs/OVERVIEW.en.md)

面向 macOS 的轻量原生笔记工作区：选择性导入 Apple Notes，在本地独立编辑待办、列表、表格和富文本。

**当前版本：0.4.0，开发试用阶段。Apple Notes 始终是只读来源，本地修改不会写回。**

## 功能

- 三栏工作区：来源、本地笔记、编辑区；原生分隔线调整栏宽并保存布局。
- 来源搜索：匹配标题、账户、文件夹；可组合筛选文件夹、附件数量、导入状态及锁定状态。
- 选择性导入与手动刷新：缓存正文、原始 HTML 和修改时间，可离线查看。
- 本地笔记：新建、修改标题、自动保存、撤销/重做及保存错误恢复。
- 待办：独立圆圈勾选；仅行尾把手启动整卡排序，拖动中实时让位，Esc 取消。
- 列表：项目符号、数字、大小写字母、大小写罗马数字；回车续号、空项退出、Tab 缩进。
- 表格：创建、追加/插入/删除行列；拖动行列重排、单元格交换；Tab 连续编辑。
- 富文本：粗体、斜体、下划线、删除线，字体、12–32 磅字号、文字颜色、高亮、段落对齐和行距。
- 链接：自动识别 URL，支持插入命名的 http/https/mailto 链接，编辑时 ⌘点击打开。
- 来源对照：格式化预览、纯文本快照，以及在 Apple Notes 中打开原文。

富文本工具适用于正文和列表，表格单元格暂不支持。编号中单独输入 `i.` / `I.` 默认识别为罗马数字。

## 项目实践

这个项目从“保留 Apple Notes 记录习惯，同时获得更灵活的本地整理能力”出发。开发重点包括：

- **原生交互**：将 SwiftUI 工作区与 AppKit 分栏、文本输入和鼠标事件结合，支持中文输入法与系统工具栏。
- **数据隔离**：把来源缓存与本地文档分开，提供只读导入、刷新保护、原子保存和冲突处理。
- **编辑模型**：使用结构化块表示待办、自动编号和表格，用可选 RTF 保留局部文字样式。
- **性能调试**：冻结拖动几何以消除反馈闪烁，限制每帧更新范围，并缓存调宽时的文字测量。
- **可验证交付**：提供演示模式、隔离回归检查、构建签名检查及手动验收清单。

## 环境要求

- macOS 14 或更新版本。
- Xcode Command Line Tools，Swift 5.9 或更新版本；如未安装，运行 `xcode-select --install`。
- 无第三方运行依赖，无需 API Key。

## 构建与运行

在项目根目录执行：

```sh
./verify.sh
./build.sh
open dist/NativeNotes.app
```

构建输出位于 `dist/NativeNotes.app`，中间文件位于 `.build/`，均不提交。构建脚本使用本地 ad-hoc 签名；应用尚未进行 Developer ID 签名或公证，建议在自己的 Mac 上从源码构建。

可将构建后的应用复制到“应用程序”目录，再从 Finder 打开。更新前退出旧版本。

### 不访问真实 Notes 的试用

```sh
open dist/NativeNotes.app --args --demo
```

演示模式使用独立存储。先退出正在运行的普通版本，再启动演示模式；也可直接新建本地笔记，无需自动化权限。

### Apple Notes 授权

1. 打开系统“备忘录”，确认目标账户及笔记已在本机可见。
2. 从 Finder 启动打包后的 NativeNotes，点击“读取来源”。
3. 系统询问是否允许控制“备忘录”时选择允许。
4. 勾选需要的笔记，点击“导入所选”。

自动化是 macOS 读取 Notes 脚本接口所需的权限，应用不执行写回操作。不需要完全磁盘访问。没有授权条目、读取失败或格式缺失时，见[故障排查](docs/TROUBLESHOOTING.md)。

## 数据与隐私

| 数据 | 本机位置 |
| --- | --- |
| 来源缓存 | `~/Library/Application Support/NativeNotes/Notes.store` 及辅助文件 |
| 本地编辑 | `~/Library/Application Support/NativeNotes/LocalEdits/*.json` |
| 演示数据 | 同目录下的 `Demo.store`、`DemoEdits/` |

本地副本用 JSON 保存正文结构，并用 RTF 保存文字样式。应用不自建云同步或遥测服务；来源云同步由 Apple Notes 负责。格式化预览会阻止自动加载外部资源；主动打开链接可能访问网络。

手动刷新仅更新来源快照，不覆盖本地编辑。源笔记不可用时保留旧缓存。多窗口版本冲突或文档损坏时停止覆盖，显示错误并允许恢复。备份时先退出应用，再复制整个 NativeNotes 数据目录。

## 导入限制

Apple Notes 的 AppleScript 导出不等于完整文档格式。普通列表可能不携带勾选状态，表格也可能仅返回嵌入对象；图片、附件、扫描和手写不保证完整导入，不会下载附件。“无附件”不等于纯文字。不能自动准确判断笔记是否是备份。

本地编辑器支持待办和表格，并不代表能还原来源中缺失的数据。普通列表不会普遍被推断成待办；手动转换后可重新确认本地完成状态。当前为兼容早期试用数据，标题为“任务列表”的文档首次打开存在特定的待办迁移规则，详见[开发说明](docs/DEVELOPMENT.md)。

## 文档

- [开发与项目结构](docs/DEVELOPMENT.md)
- [故障排查与权限](docs/TROUBLESHOOTING.md)
- [逐项手动验收](docs/ACCEPTANCE.md)
- [更新记录](CHANGELOG.md)

## 验证

`./verify.sh` 运行 88 项隔离检查，涵盖缓存、筛选、编号、待办排序、拖动几何、表格操作、富文本持久化和保存冲突。不读取真实 Apple Notes。

仓库包含 macOS 构建检查工作流。自动检查不能代表真实 Notes 格式兼容性、界面拖动手感或实际显示帧率，这些仍需手动验收。

## 图标与许可

应用使用“暖橙便笺”图标，原始图片由图像生成工具生成；`Resources/NativeNotes.icns` 包含 macOS 所需的多个尺寸。Apple Notes 为 Apple 产品名称，本项目为独立开发项目。

项目暂未指定开源许可证；上传 GitHub 不自动授予再分发或修改许可。
