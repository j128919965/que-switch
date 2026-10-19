# que-switch

NativeSwitch 是为 Apple Silicon Mac 编写的原生窗口切换器。Swift + AppKit 绘制 Win11 风格面板，SwiftUI 提供设置，ScreenCaptureKit 获取预览。无第三方依赖。

默认按 **Cmd+Tab** 切换独立窗口；同一个应用的多个窗口分别显示。每张卡片左上角使用应用自己的真实图标。

## 首次使用

1. 先退出 HyperSwitch，避免两个切换器争用快捷键。
2. 按下方说明构建，将 `dist/NativeSwitch.app` 复制到“应用程序”，再从 `/Applications/NativeSwitch.app` 打开。安装后可脱离源码目录运行。
3. 在应用的“权限”页授权“辅助功能”和“屏幕录制”。这些开关必须由你在系统设置中开启；应用不会修改权限数据库。
4. 回到应用点击“重新检测权限”。如果 macOS 要求重启应用，请退出后重新打开。
5. 短按 Cmd+Tab 切回上一个窗口；按住 Cmd 稍作停留后显示面板，继续按 Tab 前进、Shift+Tab 后退，松开 Cmd 确认。Esc 取消，方向键也可选择，点击卡片直接切换。

菜单栏图标可打开设置、暂停切换、清空缓存或退出。退出/暂停会放行系统快捷键，不修改系统的 Cmd+Tab 配置。辅助功能未授权或窗口列表未就绪时，也会放行系统快捷键。未授权屏幕录制时，可以使用应用图标切换。

## 已实现的设置

- Command / Option / Control 与 Tab / 反引号的组合；Shift 反向切换。
- 当前桌面或所有桌面；是否包含最小化和隐藏窗口。
- 面板跟随鼠标屏幕、当前窗口屏幕或主屏幕。
- 可选多屏展示：合并显示（默认）、一个面板内按屏幕分组、每个屏幕只显示自己的窗口。
- 浅色/深色/跟随系统、选中框颜色、卡片尺寸、列数、圆角、标题、毛玻璃、动画。
- 面板显示延迟（默认 100 ms）、悬停选择、关闭窗口快捷键。
- 每次呼出刷新当前页，选中窗口动态更新（默认 10 fps，可关闭）；截图缓存默认上限 48 MiB。
- 排除应用、配置 JSON 导入/导出、恢复默认设置、登录启动。

窗口很多时自动分页，Tab 跨页时加载对应缩略图。一次切换期间保持窗口顺序稳定。关闭面板后停止采集，不录音、不上传、不把截图写入磁盘。图片缓存和可见卡片之外不额外保留所有页面的截图。

## 0.2：预览居中与多屏模式

分屏窗口、竖长窗口和普通窗口均完整、等比例居中显示，不体现原窗口在屏幕上的左右位置。捕获按窗口自身宽高比设置输出尺寸，去掉阴影和捕获缓冲区的留白；单次截图与动态预览共用有效内容区域的裁切逻辑。

在“设置 → 窗口 → 面板位置 → 多屏展示”中选择：

- **合并显示（默认）**：保留原有行为，所有符合桌面范围的窗口在一个面板里按最近使用排序。
- **在一个面板内按屏幕分组**：使用屏幕名称分组，同屏窗口保持最近使用顺序；组标题会随分页重复，避免标题与卡片分离。
- **每个屏幕只显示自己的窗口**：每个屏幕同时出现各自的面板。鼠标所在屏幕接收 Tab、方向键和松开修饰键的确认操作；各屏独立保留选择。鼠标移到空屏时没有激活目标，不会意外激活另一屏的窗口。

跨屏窗口按与屏幕重叠面积最大的屏幕归属，只展示一次。支持屏幕位于主屏左侧或上方的负坐标布局。窗口移动后会更新归属；显示器插拔或布局变化时取消当前切换，下一次呼出重建面板。

多屏模式下仍然只对全局当前选中的一个窗口持续采集，静态截图总并发上限仍是 2。跟随鼠标的事件监听只在每屏模式的一次切换期间存在，关闭面板即移除。

## 构建与检查

要求 macOS 14+、Swift 5.10+ 和 Apple Command Line Tools。无需完整 Xcode、Homebrew 或第三方依赖；尚未安装命令行工具时，先运行 `xcode-select --install`。

```sh
git clone https://github.com/j128919965/que-switch.git
cd que-switch
zsh scripts/build.sh
zsh scripts/check.sh
```

输出为 `dist/NativeSwitch.app`，使用本地 ad-hoc 签名。不是经过 Apple 公证的公开发行包。重新构建会改变代码签名，系统可能要求重新授权辅助功能或屏幕录制。需要对外发行时，再使用开发者证书签名并公证。

Command Line Tools 中的 SwiftPM 可能提示找不到 XCTest 的平台路径；本项目检查工具直接运行 Swift，不依赖 XCTest，构建和检查通过时可忽略该提示。

八组检查覆盖：同一应用内不同窗口的 MRU 顺序；快速切回、正反向循环及切换中窗口关闭；迟到帧与过期会话的丢弃；旧配置兼容及导入值校验；多屏归属与负坐标；竖长窗口比例、有效区域裁切与居中；鼠标切屏、空屏及窗口跨屏移动；屏幕分组排序及选择保持。

真实 AppKit 渲染可独立生成示意截图，不显示面板、不接管快捷键、不捕获其他应用内容：

```sh
dist/NativeSwitch.app/Contents/MacOS/NativeSwitch --render-demo native-preview.png
dist/NativeSwitch.app/Contents/MacOS/NativeSwitch --render-demo native-preview-light.png --light
dist/NativeSwitch.app/Contents/MacOS/NativeSwitch --render-settings settings-preview.png performance
dist/NativeSwitch.app/Contents/MacOS/NativeSwitch --render-demo preview-centered.png --portrait
dist/NativeSwitch.app/Contents/MacOS/NativeSwitch --render-demo preview-grouped.png --portrait --grouped
```

## 实现边界

- 本地 ad-hoc 签名会随代码更新而变化。系统设置中旧条目可能仍显示开关已开，而新版系统 API 返回未授权。请先将 NativeSwitch 的对应权限关闭再开启、返回应用重新检测；必要时删除旧条目，并重新添加 `/Applications/NativeSwitch.app`。这些操作由用户在系统设置完成，不修改权限数据库。
- 最小化窗口的捕获可能暂停，显示上次快照或图标，并明确标识。
- Apple 的公开 Accessibility API 不提供窗口的 WindowServer ID。本项目用进程、标题、位置和大小进行匹配，并缓存 Accessibility 引用。如果同一应用的两个窗口标题和位置尺寸完全相同且无法唯一匹配，不会随意选择一个窗口；切换可能失败并提示。
- 使用公开 API 获取当前桌面可见窗口。最小化/隐藏窗口没有可依赖的公开 Space ID；当前桌面只显示已确认归属的窗口，切换桌面后不猜测归属。需要查看其余窗口时，可选择“所有桌面”。
- 全屏窗口和跨桌面的激活遵从 macOS 的桌面切换与动画规则；没有使用私有 Spaces API。需在用户授权后实机验证不同应用行为。
- 密码输入等安全输入场景可能限制全局按键拦截。
- 缓存上限控制的是截图像素缓存，应用总内存还包括界面、应用图标、系统捕获缓冲区和瞬时任务；不能将 48 MiB 当作总内存承诺。

## 性能验收

架构上不做后台定时抓屏，不轮询窗口列表；窗口列表通过应用/桌面通知及 Accessibility 事件刷新。快捷键回调使用独立 run loop，不执行 AX 查询或截图。窗口激活使用独立队列，避免排在窗口枚举后面。每页最多并发两次截图，持续采集仅用于当前选中窗口。捕获帧立即复制为小尺寸缩略图，避免长期占用系统捕获池。

2026-10-19 在这台 Apple Silicon、macOS 15.5 电脑上，用户完成两项系统授权并退出 HyperSwitch 后，已手动验证：

- 按住 Cmd+Tab 能显示 NativeSwitch 的窗口预览卡片。
- 修改文字或滚动页面后，再次呼出时缩略图已更新。
- 同一应用的不同窗口可以准确激活。

0.1 的本地检查：Release 构建、本地签名校验、四组核心检查、浅色/深色 AppKit 面板和设置界面渲染均通过。

0.1 版本的一次空闲采样中，`ps` 显示 CPU 0.0%；`sample` 报告物理内存占用 50.3M、当时的峰值 74.5M。该次设置窗口仍打开；RSS 为 113488 KiB，与物理 footprint 是不同口径。此数据只代表当时的试用状态，不能当作 0.2 多屏模式的性能数据、长期上限或持续切换时的性能承诺。

0.2 的 Release 构建、签名、八组核心检查，以及竖长窗口裁切、屏幕分组面板与设置页的原生渲染已通过。实机识别到内建屏与上方外接屏；用户已手动验收预览完整居中和多屏可选行为。安装版可独立于源码目录运行。

继续扩大实机验收时，可以按以下步骤检查：

1. 准备 Finder、Safari 多窗口、编辑器和终端，验证同应用窗口切换、快速连按、Shift 反向、Esc 取消、目标窗口关闭。
2. 修改浏览器/编辑器内容后再次呼出，确认缩略图刷新；选中终端运行时钟或输出，确认只有选中的预览持续更新。
3. 验证双屏、不同桌面、最小化、隐藏和全屏应用，并与系统的桌面切换行为比较。
4. 在活动监视器中分别记录空闲 60 秒和连续切换 60 秒的 CPU、内存、能耗；关闭面板后确认持续捕获结束，重复切换后内存不持续增长。

参考：[Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)、[CGEvent taps](https://developer.apple.com/documentation/coregraphics/cgevent)、[单窗口捕获与最小化窗口限制](https://developer.apple.com/videos/play/wwdc2022/10155/)。
