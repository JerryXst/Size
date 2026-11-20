# Size — macOS 窗口管理工具设计文档

> 目标：复刻 [SizeUp](https://sizeup.macupdate.com/) 的窗口管理体验，用现代 Swift 重写。
> 本文档基于对 SizeUp 1.7.4 二进制的逆向分析（见 `docs/sizeup-analysis.md`）。

---

## 1. 核心结论（逆向得到的三个关键事实）

1. **移动窗口不需要私有 API。** SizeUp 的 `WindowMover.framework` 完全使用公开的
   Accessibility API（`AXUIElementSetAttributeValue` + `AXPosition`/`AXSize`）。
   私有 API 只用在**跨 Space** 这一个功能上。
2. **32 个布局动作其实只有一个原语。** SizeUp 内部通过 AppleScript 暴露了
   `fit to grid`（默认 6×6 网格），其余所有动作都是这个原语的语法糖。
   **网格选 6 是因为 2 和 3 的最小公倍数是 6** —— 半屏（3/6）和三分屏（2/6）都能整除。
3. **兼容性的关键在「降级」，不在算法。** SizeUp 用三层策略兜底：
   AX → AppleScript → 模拟鼠标拖动。

---

## 2. 架构

```
Size/
├── Sources/
│   ├── SizeCore/              # 纯逻辑，无 UI 依赖，可单测（重点）
│   │   ├── GridAction.swift   # 32 个动作 → GridRect 的纯函数映射
│   │   ├── GridLayout.swift   # GridRect + 屏幕可见区 → CGRect
│   │   ├── ScreenGeometry.swift # NSScreen ↔ CG 坐标转换
│   │   └── ActionResolver.swift # 动作 + 屏幕 + 配置 → 目标 CGRect
│   ├── SizeAX/                # Accessibility 封装
│   │   ├── AXPermission.swift
│   │   ├── AXWindow.swift     # 窗口抽象（pid, element, frame, subrole）
│   │   ├── AXWindowMover.swift # 核心：设 frame + 回读校验 + 重试
│   │   └── AXAppEnumerator.swift
│   ├── SizeSpaces/            # 跨 Space（私有 API，可选功能）
│   │   └── SkyLightBridge.swift
│   └── SizeApp/               # AppKit UI 层
│       ├── AppDelegate.swift
│       ├── StatusMenuController.swift
│       ├── HotkeyCenter.swift
│       └── SettingsView.swift
└── Tests/SizeCoreTests/
```

**分层原则**：`SizeCore` 是纯函数库，输入是矩形和参数，输出是目标矩形。
所有坐标计算、多显示器、Dock 位置、margin 的复杂逻辑都在这一层，
意味着 **90% 的逻辑可以用单元测试覆盖，不需要真的移动窗口**。

---

## 3. 核心原语：fit to grid

### 3.1 定义

```swift
/// 网格坐标，0-based，原点在左上
public struct GridRect: Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
}

/// 唯一原语：把窗口放进屏幕可见区的指定网格子矩形
/// - Parameters:
///   - gridRect: 网格坐标
///   - gridSize: 网格尺寸，默认 6×6
///   - screen: 目标屏幕的 visibleFrame（已排除菜单栏和 Dock）
///   - margin: 四边留白
/// - Returns: 目标 frame（NS 坐标系，左下原点）
public func frame(for gridRect: GridRect, in gridSize: GridSize, screen: CGRect, margin: EdgeInsets) -> CGRect
```

### 3.2 坐标换算

设 `screen` 为屏幕 visibleFrame（宽 W，高 H），留白 `m`（上 t、下 b、左 l、右 r）：

```
可用区 = CGRect(
    x: screen.minX + l,
    y: screen.minY + b,
    width:  screen.width  - l - r,
    height: screen.height - t - b
)

单元格宽 u = 可用区.width  / gridSize.columns
单元格高 v = 可用区.height / gridSize.rows

结果 = CGRect(
    x: 可用区.minX + gridRect.x * u,
    y: 可用区.minY + (gridSize.rows - gridRect.y - gridRect.height) * v,  // ⚠️ Y 轴翻转
    width:  gridRect.width  * u,
    height: gridRect.height * v
)
```

> **⚠️ 最容易出错的点**：网格坐标原点在**左上**（符合人的直觉），
> 而 NS 坐标原点在**左下**。所以 Y 必须翻转：
> `nsY = rows - gridY - gridHeight`。
> 建议统一用「左上原点」的相对网格坐标做全部计算，只在最后一步转 NS 坐标。

为了消除浮点累积误差，**边界用累加取整而非宽度相乘**：

```swift
let edges = (0...gridSize.columns).map { (可用区.minX + 可用区.width * $0 / gridSize.columns).rounded() }
let x = edges[gridRect.x]
let w = edges[gridRect.x + gridRect.width] - x
```

这样「左半分屏 + 右半分屏」拼起来正好等于全屏，不会有 1px 缝。

---

## 4. 32 个动作的网格坐标表

网格固定 **6×6**。（选 6 的理由见第 1 节）

| # | 动作 | GridRect (x, y, w, h) | 说明 |
|---|------|----------------------|------|
| 1 | `left` | (0, 0, 3, 6) | 左半屏 |
| 2 | `right` | (3, 0, 3, 6) | 右半屏 |
| 3 | `up` | (0, 0, 6, 3) | 上半屏 |
| 4 | `down` | (0, 3, 6, 3) | 下半屏 |
| 5 | `upperLeft` | (0, 0, 3, 3) | 左上四分之一 |
| 6 | `upperRight` | (3, 0, 3, 3) | 右上 |
| 7 | `lowerLeft` | (0, 3, 3, 3) | 左下 |
| 8 | `lowerRight` | (3, 3, 3, 3) | 右下 |
| 9 | `fullScreen` | (0, 0, 6, 6) | 铺满可见区 |
| 10 | `thirdLeft` | (0, 0, 2, 6) | 左三分之一 |
| 11 | `thirdCenter` | (2, 0, 2, 6) | 中三分之一 |
| 12 | `thirdRight` | (4, 0, 2, 6) | 右三分之一 |
| 13 | `thirdUpper` | (0, 0, 6, 2) | 上三分之一 |
| 14 | `thirdMiddle` | (0, 2, 6, 2) | 中三分之一（横） |
| 15 | `thirdLower` | (0, 4, 6, 2) | 下三分之一 |
| 16 | `twoThirdsLeft` | (0, 0, 4, 6) | 左 2/3（扩展项） |
| 17 | `twoThirdsRight` | (2, 0, 4, 6) | 右 2/3（扩展项） |

### 特殊动作（不走网格）

| # | 动作 | 行为 |
|---|------|------|
| 18 | `center` | **保持尺寸**，水平垂直居中 |
| 19 | `snapBack` | 恢复到保存的原始 frame |
| 20 | `prevMonitor` | 移到上一台显示器的对应相对位置 |
| 21 | `nextMonitor` | 移到下一台显示器 |

### 只移动不缩放（move*，保持 size）

| # | 动作 | 行为 |
|---|------|------|
| 22-25 | `moveLeft/Right/Up/Down` | 水平/垂直贴边，另一轴保持不变 |
| 26-29 | `moveUpperLeft/UpperRight/LowerLeft/LowerRight` | 窗口角对齐屏幕角 |
| 30 | `moveCenter` | 居中，保持尺寸（同 `center`） |
| 31 | `nextSpace` / `prevSpace` | 跨 Space（需私有 API） |
| 32 | `spaceAbove` / `spaceBelow` | 跨 Space 垂直方向 |

> **待真机验证**：`moveLeft` 的语义有两种可能——
> (a) 窗口左边缘贴屏幕左边，垂直位置不变；(b) 贴边并垂直居中。
> 建议先实现 (a)，符合「只改位置」的直觉。

### 实现方式

```swift
public enum WindowAction: String, CaseIterable {
    case left, right, up, down
    case upperLeft, upperRight, lowerLeft, lowerRight
    case fullScreen, center, snapBack
    case thirdLeft, thirdCenter, thirdRight
    case thirdUpper, thirdMiddle, thirdLower
    case prevMonitor, nextMonitor
    case moveLeft, moveRight, moveUp, moveDown
    case moveUpperLeft, moveUpperRight, moveLowerLeft, moveLowerRight

    /// 对应的网格矩形；nil 表示该动作不走网格原语
    public var gridRect: GridRect? { ... }
}
```

**32 个动作 = 一张静态表 + 一个通用换算函数。** 不要为每个动作单独写坐标计算。

---

## 5. Accessibility 层设计

### 5.1 权限

- 需要「辅助功能」授权：`AXIsProcessTrustedWithOptions` + `kAXTrustedCheckOptionPrompt`
- **不能开 App Sandbox**（沙盒内 AX 基本不可用）→ 无法上 Mac App Store
- 开发期技巧：固定 Bundle ID + 用一张自签证书稳定签名，否则每次重编译都要重新授权

### 5.2 窗口枚举

```swift
// 1. 拿到所有普通 App
NSWorkspace.shared.runningApplications
    .filter { $0.activationPolicy == .regular }

// 2. 每个 App 拿窗口
let appEl = AXUIElementCreateApplication(pid)
let windows: [AXUIElement] = copyAttribute(appEl, kAXWindowsAttribute)

// 3. 过滤：只要标准窗口
subrole == kAXStandardWindow   // 排除对话框、浮动面板、tooltip、popover
```

**必须设超时**，否则目标 App 卡死会连累自己：

```swift
AXUIElementSetMessagingTimeout(element, 0.5)
```

### 5.3 设置 frame 的正确姿势（关键）

```swift
func setFrame(_ target: CGRect, on window: AXUIElement) -> Bool {
    // 1. 原生全屏状态不能直接改尺寸，先退出全屏
    if isFullScreen(window) {
        setAttribute(window, kAXFullScreenAttribute, false)
        waitForExitFullScreen(window, timeout: 1.0)   // 等动画结束，别立即设 frame
    }

    // 2. 先 position 后 size（顺序对某些 App 有影响）
    //    注意：position 传的是「左上角」还是「左下角」？
    //    AXPosition 用的是 CG 坐标（左上原点，Y 向下）！
    let cgPosition = CGPoint(x: target.minX, y: cgY(for: target.minY, height: target.height))
    setAttribute(window, kAXPositionAttribute, cgPosition)
    setAttribute(window, kAXSizeAttribute, target.size)

    // 3. 回读校验 —— 这一步不能省
    guard let actual = readFrame(window) else { return false }
    if !approximatelyEqual(actual, target, tolerance: 2.0) {
        // App 做了约束修正，最多重试 2 次
    }
    return true
}
```

> **⚠️ 坐标系陷阱**：AX 的 `kAXPositionAttribute` 用的是 **CoreGraphics 全局坐标
> （主屏左上角为原点，Y 向下）**，而 `NSScreen.frame` 是 **左下原点，Y 向上**。
> 转换公式（`mainScreen` = `NSScreen.screens[0]`）：
> ```swift
> let cgY = mainScreen.frame.height - nsRect.maxY
> ```
> 多显示器高度不一致时必须在进入 AX 层之前统一转换，**层内只用一种坐标系**。

### 5.4 三层降级策略（照抄 SizeUp）

```
WindowMover（调度）
├─ AXWindowMover      ← 默认，覆盖 95% 的 App
├─ ASWindowMover      ← 兜底：按 bundleID 用 AppleScript 驱动
└─ MouseWindowMover   ← 最后：模拟鼠标拖动标题栏
```

**第一版只实现 AX 层**。遇到移不动的 App 记录到忽略列表即可，
不要一开始就写 AppleScript 脚本体系——那是 SizeUp 面对十几年前
不听话的 Office 攒出来的历史包袱，现代 App 大多能正常响应 AX。

### 5.5 兼容性 Checklist（真机逐项验证）

- [ ] Finder 窗口
- [ ] Safari / Chrome / Arc
- [ ] VS Code / Cursor（Electron，响应慢，需要更长超时）
- [ ] Terminal / iTerm2
- [ ] 微信 / QQ / Telegram
- [ ] 原生全屏中的窗口（先退全屏）
- [ ] 已被最大化的窗口
- [ ] 有最小尺寸限制的窗口（如系统设置）
- [ ] 带 Drawer / Inspector 的窗口
- [ ] 对话框（应被过滤掉，不该被移动）
- [ ] 多显示器 + 不同分辨率
- [ ] Dock 在左 / 在右 / 自动隐藏

---

## 6. 跨显示器与跨 Space

### 6.1 跨显示器（纯公开 API）

计算窗口中心点落在哪块屏，按相对比例映射到目标屏：

```swift
// 相对位置保持不变，而不是直接搬过去
let relativeX = (window.midX - sourceScreen.minX) / sourceScreen.width
let targetX = destScreen.minX + relativeX * destScreen.width
```

### 6.2 跨 Space（私有 API，风险最高）

**在 macOS 27.2.1 上的实测结果**（`dlsym` 探测，本项目已验证）：

| 符号 | CoreGraphics | SkyLight |
|------|:---:|:---:|
| `_CGSDefaultConnection` | ✅ | ✅ |
| `CGSGetWorkspace` | ✅ | ✅ |
| `CGSMoveWorkspaceWindowList` | ✅ | ✅ |
| `CGSSetWorkspace` | ❌ | ❌ |
| `SLSCopySpacesForWindows` | ❌ | ✅ |
| `SLSAddWindowsToSpaces` | ❌ | ✅ |
| `SLSRemoveWindowsFromSpaces` | ❌ | ✅ |
| `SLSCopyManagedDisplaySpaces` | ❌ | ✅ |
| `SLSGetActiveSpace` | ❌ | ✅ |

**结论**：
1. SizeUp 用的 `CGSSetWorkspace` 在新系统上**已消失** —— 这是它 Space 功能失效的原因。
2. 新方案应使用 SkyLight 的 `SLSCopySpacesForWindows` + `SLSRemoveWindowsFromSpaces`/`SLSAddWindowsToSpaces` 组合。
3. `dlsym` 能解析**只证明符号存在**，不证明签名和语义未变 —— **必须真机实测**。

**功能开关**：跨 Space 默认关闭，在设置里显式开启，并在失效时优雅降级（不崩溃、不弹错）。

**前置条件**（SizeUp 踩过的坑，必须检查并引导用户）：
- 系统设置 → 桌面与程序坞 → Mission Control 里「自动重新排列 Space」必须**关闭**
- 全屏 Space 不支持跨 Space 移动
- 浮动面板不支持

**建议**：M5 才做，且做成独立模块 `SizeSpaces`，失败时整个模块禁用不影响主功能。

---

## 7. 配置模型

```swift
struct MarginConfig {
    var top: Double = -1      // -1 = 使用全局默认
    var bottom: Double = -1
    var left: Double = -1
    var right: Double = -1
}

struct AppOverride {
    var disabled: Bool = false          // 忽略此 App
    var margin: MarginConfig?
    var actionParams: [String: GridRect]?  // 按动作覆盖网格
}

// 全局配置
struct Config {
    var defaultMargin: MarginConfig = .init(top: 0, bottom: 0, left: 0, right: 0)
    var gridSize: (columns: Int, rows: Int) = (6, 6)
    var ignoredBundleIDs: Set<String> = []
    var overrides: [String: AppOverride] = [:]   // key = bundleID
    var enableSpaceActions: Bool = false
}
```

**借用 SizeUp 的两个巧思**：
1. `-1` 表示「继承默认值」，避免 null 判断
2. 给配置 key 加 `.disabled` 后缀即可停用某条规则，不用删配置

配置存 `~/Library/Application Support/Size/config.json`，
热键存 `UserDefaults`（用 `KeyboardShortcuts` 库）。

---

## 8. 热键

用 [`sindresorhus/KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts)：

- 底层是 Carbon `RegisterEventHotKey`，**不占事件流、不需要额外权限**
- **不要**用 `NSEvent.addGlobalMonitorForEvents`（监听需要额外权限，且无法拦截）

热键冲突检测：注册失败时提示用户，并引导到系统设置修改冲突项。

**默认键位建议**（尽量避开系统占用）：

| 动作 | 键位 |
|------|------|
| 左/右/上/下半屏 | `⌃⌥ ←/→/↑/↓` |
| 四象限 | `⌃⌥ + U/I/J/K` |
| 全屏 | `⌃⌥ ↩` |
| 居中 | `⌃⌥ C` |
| 三分屏 | `⌃⌥ D/F/G`（左右中） |
| 上一台/下一台显示器 | `⌃⌥ ,` / `⌃⌥ .` |
| SnapBack | `⌃⌥ ⌫` |

---

## 9. 菜单栏

`LSUIElement = true`（无 Dock 图标），`NSStatusItem` + 下拉菜单：

```
┌─────────────────────────┐
│ Move Window             │
├─────────────────────────┤
│ Left        ⌃⌥←         │
│ Right       ⌃⌥→         │
│ ...                     │
├─────────────────────────┤
│ Send to Monitor ▸       │
│ │  Built-in Display     │
│ │  DELL U2720Q          │
├─────────────────────────┤
│ SnapBack    ⌃⌥⌫         │
├─────────────────────────┤
│ Preferences…            │
│ Quit                    │
└─────────────────────────┘
```

图标三态（照抄 SizeUp）：normal / dark（暗色模式）/ dim（不可用）。

---

## 10. 里程碑

| 阶段 | 内容 | 验收标准 | 估时 |
|------|------|----------|------|
| **M0** | AX 授权 → 枚举窗口 → 改一个窗口的 frame | 能把 Safari 窗口设为左半屏 | 半天 |
| **M1** | `fit to grid` 原语 + 32 动作表 + 单测 | 32 个动作的坐标计算全部测试通过 | 1 天 |
| **M2** | 菜单栏 + 全局热键 + 忽略列表 | 用热键能操作任意窗口 | 1 天 |
| **M3** | Margin + 网格尺寸配置 + per-App override | 带 10px 间距的分屏可用 | 1-2 天 |
| **M4** | 回读校验 / 重试 / 全屏退出 / SnapBack / 跨显示器 | 兼容性 checklist 全部通过 | 2-3 天 |
| **M5** | 跨 Space（SkyLight，可选） | 真机验证通过，失败时优雅降级 | 2-3 天 |

---

## 11. 不做的事（明确的边界）

- ❌ App Sandbox（AX 不可用）
- ❌ Mac App Store 上架
- ❌ AppleScript 脚本体系（第一版不写，用忽略列表替代）
- ❌ 鼠标拖动时自动吸附（SizeUp 也没有，是另一个产品形态）
- ❌ 32 位 / Intel 支持（只做 arm64）
- ❌ BWToolkit 等老 UI 库（用 SwiftUI）
- ❌ Sparkle 自动更新（自用不需要）

---

## 12. 构建与环境注意事项（实机踩坑记录）

### 12.1 macOS 27 SDK：CoreGraphics 不再隐式导入

从 macOS 27 起，`import Foundation` **不再自动带出 CoreGraphics** 的 `CGRect` 扩展。
症状很像别的错误：

```
error: value of type 'CGRect' has no member 'minX'
error: argument passed to call that takes no arguments   // CGRect(x:y:width:height:)
```

**解决**：任何用到 `CGRect` / `CGFloat` / `CGPoint` / `CGSize` 的文件都必须显式
`import CoreGraphics`。实测 macOS 27.2 + Swift 6.4.2 下必然遇到。

### 12.2 `kAXFullScreenAttribute` 不存在于公开 API

全屏属性没有公开的 Swift 常量，必须用字符串访问：

```swift
private static let fullScreenAttribute = "AXFullScreen"
let isFull = (copyAttribute(w, "AXFullScreen") as? NSNumber)?.boolValue ?? false
```

### 12.3 需要排除自身进程

枚举窗口时必须过滤掉自己的 pid，否则工具会去调整自己的窗口（出现反馈循环）：

```swift
let ownPID = ProcessInfo.processInfo.processIdentifier
apps.filter { $0.processIdentifier != ownPID }
```

注意这只能排除工具自己；像 Nomi、微信这类**其它** App 仍会出现在列表里，
想屏蔽它们得靠「忽略列表」（M3）。

---

## 13. 参考资料

- [Rectangle](https://github.com/rxhanson/Rectangle) — Swift/MIT，工业级实现，架构高度参考
- [Loop](https://github.com/MrKai77/Loop) — 径向菜单 + 平滑动画参考
- [yabai](https://github.com/koekeishiya/yabai) — 私有 API 使用参考
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — 热键库
