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
- 每次呼出为可见窗口各截图一次，翻到新页面时补齐预览；停留和反复选择不重复采集。截图缓存默认上限 48 MiB。
- 电池供电或低电量模式下默认使用 1 倍分辨率预览，可在“预览与性能”中关闭此优化。
- 排除应用、配置 JSON 导入/导出、恢复默认设置、登录启动。

窗口很多时自动分页，Tab 跨页时加载对应缩略图。一次切换期间保持窗口顺序稳定。关闭面板后不再提交截图请求，已提交给系统的单次请求完成后会丢弃过期结果。不录音、不上传、不把截图写入磁盘。

## 0.3：按需截图与切换响应

- 移除持续录制流和动态预览设置。旧配置中的 `livePreview`、`previewFPS` 会被忽略，不会因升级后残留的开关再次开启录制。系统仍可能对单次截图显示隐私提示。
- 同一轮切换中，每个可见窗口最多请求一次截图，优先处理选中项；Tab、鼠标选择、窗口标题变化和返回已加载页面均不会重抓。下次呼出重新刷新，避免旧缩略图长期不更新。
- 所有截图共用一个串行工作任务。快速关闭再呼出也等待已有的系统请求返回，不叠加采集；页面切换会丢弃尚未提交的离屏请求。
- 立即显示已有缓存，再异步补齐新截图。电池供电或低电量模式下，默认从 Retina 2 倍降至 1 倍缩略图，即相同逻辑尺寸的像素数降为四分之一；卡片尺寸和居中规则保持一致。
- 切换选择只更新变化的卡片状态，标题变化原位更新；相同缩略图不会反复转成新图片或触发布局。
- 切换面板显示与窗口激活期间使用有起止配对的用户活动标记，避免交互被 App Nap 延后。结束后立即释放，不全局禁用系统节能。激活应用不再等待恢复一个本来就未最小化的窗口。

本机用户已在拔电状态手动验证：按住 Cmd+Tab 停留、继续切换与松开 Cmd 后，不再持续出现录屏提示闪烁，窗口切换流畅。

## 0.2：预览居中与多屏模式

分屏窗口、竖长窗口和普通窗口均完整、等比例居中显示，不体现原窗口在屏幕上的左右位置。捕获按窗口自身宽高比设置输出尺寸，去掉阴影和捕获缓冲区的留白，并按有效内容区域裁切。

在“设置 → 窗口 → 面板位置 → 多屏展示”中选择：

- **合并显示（默认）**：保留原有行为，所有符合桌面范围的窗口在一个面板里按最近使用排序。
- **在一个面板内按屏幕分组**：使用屏幕名称分组，同屏窗口保持最近使用顺序；组标题会随分页重复，避免标题与卡片分离。
- **每个屏幕只显示自己的窗口**：每个屏幕同时出现各自的面板。鼠标所在屏幕接收 Tab、方向键和松开修饰键的确认操作；各屏独立保留选择。鼠标移到空屏时没有激活目标，不会意外激活另一屏的窗口。

跨屏窗口按与屏幕重叠面积最大的屏幕归属，只展示一次。支持屏幕位于主屏左侧或上方的负坐标布局。窗口移动后会更新归属；显示器插拔或布局变化时取消当前切换，下一次呼出重建面板。

多屏模式下，所有屏幕的单次截图共用同一个串行工作任务，没有持续采集。跟随鼠标的事件监听只在每屏模式的一次切换期间存在，关闭面板即移除。

## 构建与检查

要求 macOS 14+、Swift 5.10+ 和 Apple Command Line Tools。无需完整 Xcode、Homebrew 或第三方依赖；尚未安装命令行工具时，先运行 `xcode-select --install`。

```sh
git clone https://github.com/j128919965/que-switch.git
cd que-switch
zsh scripts/build.sh
zsh scripts/check.sh
```

输出为 `dist/NativeSwitch.app`，使用本地 ad-hoc 签名。不是经过 Apple 公证的公开发行包。重新构建会改变代码签名，系统可能要求重新授权辅助功能或屏幕录制。需要对外发行时，再使用开发者证书签名并公证。

## 更新本机安装版

本机应用安装在 `/Applications/NativeSwitch.app`，与源码目录独立。偏好设置由 macOS UserDefaults 保存，覆盖应用不需要重置配置。以下流程已用于本机从 0.2.0 更新至 0.3.0，并验证两项权限重新授权成功。

1. 从菜单栏退出 NativeSwitch。保留旧版备份，确认源码修改已提交后，在仓库目录执行：

   ```sh
   git pull --ff-only
   zsh scripts/check.sh
   zsh scripts/build.sh
   ```

2. 检查通过后，备份旧版，再覆盖安装。备份目录使用不同名称，避免覆盖此前的回退版本：

   ```sh
   backup_dir=".build/backups/$(date +%Y%m%d-%H%M%S)"
   mkdir -p "$backup_dir"
   ditto /Applications/NativeSwitch.app "$backup_dir/NativeSwitch.app"
   ditto dist/NativeSwitch.app /Applications/NativeSwitch.app
   codesign --verify --strict /Applications/NativeSwitch.app
   open /Applications/NativeSwitch.app
   ```

3. 打开“设置 → 权限”，点击“重新检测权限”。如果两项均已授权，直接进入验收；如果显示未授权，或系统开关已开但应用仍显示未授权，按下一节重新申请。
4. 验证 Cmd+Tab、同应用多窗口、修改内容后再次呼出的新预览，以及启用的多屏模式。0.3.0 还需验证：停留时预览静止、没有持续采集；拔电后连续切换与松开 Cmd 的响应。
5. 授权完成后使用当前安装包，不再重复构建或重新签名同一版本。再次构建会产生新的本地签名，可能需要再次授权。若需要回退，先退出应用，再把备份的 `.app` 复制回 `/Applications`；回退后同样重新检测权限。

### 本地签名变化后的干净授权流程

本地 ad-hoc 签名会随二进制更新而变化。macOS 可能保留旧版条目，出现“系统设置开关已开，但新版读取到未授权”的状态。仅关闭再打开开关有时仍不能恢复；本机已通过以下流程恢复：

1. 先退出 NativeSwitch，避免运行中的进程保留旧权限状态。
2. 在终端执行，只清除这个应用的两项授权记录：

   ```sh
   tccutil reset Accessibility com.que.NativeSwitch
   tccutil reset ScreenCapture com.que.NativeSwitch
   open /Applications/NativeSwitch.app
   ```

   两条重置命令均应返回 `Successfully reset`。必须保留 `com.que.NativeSwitch` 参数，限定为本应用；不需要 `sudo`，也不直接编辑系统权限数据库。此操作不删除偏好设置、源码或其他应用的权限。

3. 在 NativeSwitch“设置 → 权限”中分别点击“请求授权”，由用户在“系统设置 → 隐私与安全性”中开启 NativeSwitch 的“辅助功能”和“录屏与系统录音”（不同系统版本可能显示“屏幕录制”）。
4. 按系统提示退出并重新打开应用，回到权限页点击“重新检测权限”，确认两项都显示“已授权”。以应用实际检测结果为准，而不只看系统设置中的开关。
5. 手动测试 Cmd+Tab。不要为这一步重新构建应用，否则会再次改变刚获得授权的代码签名。

参考：[Apple：重置 macOS 受保护资源的访问权限](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos)。

## 检查覆盖与界面验证

Command Line Tools 中的 SwiftPM 可能提示找不到 XCTest 的平台路径；本项目检查工具直接运行 Swift，不依赖 XCTest，构建和检查通过时可忽略该提示。

十组核心检查覆盖窗口 MRU、切换操作、过期会话、配置迁移、多屏归属、预览居中、多屏路由、分组排序、截图去重和供电模式预算。四组预览集成检查使用真实预览服务和模拟截图后端，验证停留不抓图、快速重开无并发叠加、关闭后丢弃任务、捕获失败不重试风暴；不捕获其他应用的真实内容。

真实 AppKit 渲染可独立生成示意截图，不显示面板、不接管快捷键、不捕获其他应用内容：

```sh
dist/NativeSwitch.app/Contents/MacOS/NativeSwitch --render-demo native-preview.png
dist/NativeSwitch.app/Contents/MacOS/NativeSwitch --render-demo native-preview-light.png --light
dist/NativeSwitch.app/Contents/MacOS/NativeSwitch --render-settings settings-preview.png performance
dist/NativeSwitch.app/Contents/MacOS/NativeSwitch --render-demo preview-centered.png --portrait
dist/NativeSwitch.app/Contents/MacOS/NativeSwitch --render-demo preview-grouped.png --portrait --grouped
dist/NativeSwitch.app/Contents/MacOS/NativeSwitch --render-demo preview-updates.png --portrait --check-panel-updates
```

## 实现边界

- 本地 ad-hoc 签名会随代码更新而变化。系统设置中旧条目可能仍显示开关已开，而新版系统 API 返回未授权。遇到这种情况，使用上方“本地签名变化后的干净授权流程”，只重置本应用的授权记录，再由用户重新开启系统权限。
- 最小化窗口的捕获可能暂停，显示上次快照或图标，并明确标识。
- Apple 的公开 Accessibility API 不提供窗口的 WindowServer ID。本项目用进程、标题、位置和大小进行匹配，并缓存 Accessibility 引用。如果同一应用的两个窗口标题和位置尺寸完全相同且无法唯一匹配，不会随意选择一个窗口；切换可能失败并提示。
- 使用公开 API 获取当前桌面可见窗口。最小化/隐藏窗口没有可依赖的公开 Space ID；当前桌面只显示已确认归属的窗口，切换桌面后不猜测归属。需要查看其余窗口时，可选择“所有桌面”。
- 全屏窗口和跨桌面的激活遵从 macOS 的桌面切换与动画规则；没有使用私有 Spaces API。需在用户授权后实机验证不同应用行为。
- 密码输入等安全输入场景可能限制全局按键拦截。
- 缓存上限控制的是截图像素缓存，应用总内存还包括界面、应用图标、系统捕获缓冲区和瞬时任务；不能将 48 MiB 当作总内存承诺。

## 性能验收

架构上不做后台定时抓屏，不轮询窗口列表；窗口列表通过应用/桌面通知及 Accessibility 事件刷新。快捷键回调使用独立 run loop，不执行 AX 查询或截图。窗口激活使用独立队列，避免排在窗口枚举后面。预览使用单次截图 API 和全局串行任务，不创建 `SCStream`；捕获缓冲区立即复制为小尺寸缩略图，避免长期占用系统捕获池。

2026-10-19 在这台 Apple Silicon、macOS 15.5 电脑上，用户完成两项系统授权并退出 HyperSwitch 后，已手动验证：

- 按住 Cmd+Tab 能显示 NativeSwitch 的窗口预览卡片。
- 修改文字或滚动页面后，再次呼出时缩略图已更新。
- 同一应用的不同窗口可以准确激活。

0.1 的本地检查：Release 构建、本地签名校验、四组核心检查、浅色/深色 AppKit 面板和设置界面渲染均通过。

0.1 版本的一次空闲采样中，`ps` 显示 CPU 0.0%；`sample` 报告物理内存占用 50.3M、当时的峰值 74.5M。该次设置窗口仍打开；RSS 为 113488 KiB，与物理 footprint 是不同口径。此数据只代表当时的试用状态，不能当作 0.2 多屏模式的性能数据、长期上限或持续切换时的性能承诺。

0.2 的 Release 构建、签名、八组核心检查，以及竖长窗口裁切、屏幕分组面板与设置页的原生渲染已通过。实机识别到内建屏与上方外接屏；用户已手动验收预览完整居中和多屏可选行为。安装版可独立于源码目录运行。

0.3 的 Release 构建、本地签名、十组核心检查、四组预览服务集成检查、普通与屏幕分组面板的连续选择和标题更新检查，以及预览居中和设置页渲染均已通过。本机安装后已重新授权两项权限；用户已在拔电状态验收“不再持续闪烁，切换也流畅”。

继续扩大实机验收时，可以按以下步骤检查：

1. 准备 Finder、Safari 多窗口、编辑器和终端，验证同应用窗口切换、快速连按、Shift 反向、Esc 取消、目标窗口关闭。
2. 修改浏览器/编辑器内容后再次呼出，确认缩略图刷新；选中终端运行时钟或输出，确认停留时预览保持静止，再次呼出才显示新快照。
3. 验证双屏、不同桌面、最小化、隐藏和全屏应用，并与系统的桌面切换行为比较。
4. 在活动监视器中分别记录空闲 60 秒和连续切换 60 秒的 CPU、内存、能耗；关闭面板后确认持续捕获结束，重复切换后内存不持续增长。

参考：[Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)、[CGEvent taps](https://developer.apple.com/documentation/coregraphics/cgevent)、[单窗口捕获与最小化窗口限制](https://developer.apple.com/videos/play/wwdc2022/10155/)。
