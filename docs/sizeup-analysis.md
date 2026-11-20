# SizeUp 1.7.4 逆向分析报告

> 分析对象：`~/Downloads/Sizeup.app`
> 分析环境：macOS 27.2.1 (26B131), arm64
> 分析方法：包结构检查、`Info.plist`、`otool -L`、`nm -u`、`strings`、`dlsym` 符号探测、`.sdef` 解析

---

## 1. 基本信息

| 项 | 值 |
|---|---|
| Bundle ID | `com.irradiatedsoftware.SizeUp` |
| 版本 | 1.7.4 (build 1360) |
| 发布日期 | 2018-09-23 |
| 架构 | **x86_64 + i386**（无 arm64） |
| 最低系统 | 10.6.6 |
| 签名 | Developer ID Application: Irradiated Software, LLC (TeamID `GVZ7RF955D`)，**未公证** |
| `LSUIElement` | `true`（无 Dock 图标，纯菜单栏 App） |
| `NSPrincipalClass` | `MyApplication` |
| AppleScript | `NSAppleScriptEnabled=true`，`OSAScriptingDefinition=SizeUp.sdef` |
| 更新机制 | Sparkle（`SUFeedURL` + DSA 签名） |
| 崩溃上报 | 自研 `CMCrashReporter`（提交到 irradiatedsoftware.com） |

> **在当前系统上基本不可用**：只有 x86_64/i386，需要 Rosetta 2；且旧跨 Space API 已失效（见第 5 节）。

---

## 2. 内嵌 Framework

```
Contents/Frameworks/
├── WindowMover.framework        ← 核心：窗口移动引擎（weak link）
├── ShortcutRecorder.framework   ← 热键录制控件
├── Sparkle.framework            ← 自动更新
├── BWToolkitFramework.framework ← 第三方 UI 控件库（Brandon Walkin，已废弃）
└── CMCrashReporter.framework    ← 崩溃上报
```

主程序链接了 `AppleScriptKit`、`Carbon`、`Security`、`libcrypto.0.9.8`。

---

## 3. WindowMover：三层降级架构（核心发现）

### 3.1 类结构

从 `nm -U` 提取的 ObjC 类：

```
WindowMover                     ← 调度器
AbstractWindowMover             ← 抽象基类（anchorPoint, bounds, shouldClickToUnmunge）
├── AXWindowMover               ← 默认路径，公开 AX API
├── ASWindowMover               ← AppleScript 兜底
└── MouseWindowMover            ← 模拟鼠标拖动

辅助类：
AXUtils         ← AX 封装（设属性 + 回读校验）
ASUtils         ← AppleScript 封装
CGUtils         ← CoreGraphics 工具
DockUtils       ← Dock 位置计算
ScreenUtils     ← 屏幕几何（CGSizeForScreen:inset: 等）
ProcessUtils    ← 进程枚举
```

调度入口：

```objc
- mostAppropriateWindowMoverForAppWithPID:withDrawers:
- mostAppropriateWindowMoverForFocusedAppWithDrawers:
```

### 3.2 AXWindowMover 使用的属性（全部公开）

```
AXWindows          AXFocusedWindow    AXMainWindow
AXRole             AXSubrole          AXTitle
AXPosition         AXSize             AXFullScreen
AXRaise            AXChildren         AXDialog
AXDefaultButton    AXFrontmost        AXMain
```

IVar：`_application`, `_window`, `_hasDrawers`,
`_drawerDown`, `_drawerLeft`, `_drawerRight`, `_drawerUp`

> **Drawer 支持是历史包袱**：老式抽屉面板（如 Mail 的侧栏）现在已不常见，复刻时可以砍掉。

### 3.3 AX 层依赖的符号（全部公开 API）

```
_AXAPIEnabled                    _AXUIElementCopyAttributeNames
_AXUIElementCopyAttributeValue   _AXUIElementCopyAttributeValues
_AXUIElementCopyElementAtPosition _AXUIElementCreateApplication
_AXUIElementCreateSystemWide     _AXUIElementGetAttributeValueCount
_AXUIElementGetPid               _AXUIElementGetTypeID
_AXUIElementIsAttributeSettable  _AXUIElementPerformAction
_AXUIElementSetAttributeValue    _AXValueCreate
_AXValueGetType                  _AXValueGetValue
```

**结论：移动和调整窗口尺寸完全不需要私有 API。**

### 3.4 错误处理字符串（说明它踩过的坑）

```
Error moving window
Error raising window
Error resizing window
Error resizing window, got a zero size          ← App 返回 0 尺寸
Error retreiving window position
Error retreiving window size
AXWMI: Window was NULL
Couldn't get monitor list to get screen with window point, returning main monitor instead
Couldn't get monitor list to get screen with window rect, returning main monitor instead
No monitor matched screenWithWindowCGRect, returning main monitor instead
```

> 印证了 DESIGN.md 的核心判断：**兼容性靠回读校验和降级兜底，不是靠算法。**

---

## 4. AppleScript 兜底层

### 4.1 脚本清单

`Frameworks/WindowMover.framework/Versions/A/Resources/Scripts/WindowMovers/`：

```
com.microsoft.Excel.scpt          com.microsoft.Word.scpt
com.microsoft.PowerPoint.scpt     com.microsoft.Entourage.scpt
com.apple.garageband.scpt         com.apple.iPhoto.scpt
com.apple.iDVD.scpt               com.apple.SystemPreferences.scpt
com.barebones.bbedit.scpt         com.elgato.eyetv.scpt
com.writebros.Screenwriter.scpt   it.bloop.airmail.scpt
com.CircusPonies.NoteBook.scpt    com.circusponies.NoteBookMac.scpt
GenericAS.scpt
```

### 4.2 脚本内部协议（从编译字节码反推）

```
use_ax       → 脚本自己判断「这个 App 其实能用 AX，别走我这条路径」
reanchor     → 重新锚定窗口
move_window  → 主入口，参数 inWidth / inHeight
is_resizable
parse_short_version
minWidth / minHeight / fixLeft / dockLeft   ← 按 App 硬编的尺寸修正
```

`osadecompile` 报 `errOSASourceNotAvailable (-1756)`，说明脚本编译时**未保存源码**，只能从字节码字符串常量推断。

> 注意 `is_resizable` / `minWidth` / `minHeight` / `fixLeft` / `dockLeft` 这些名字：
> 说明即使走 AppleScript，也要处理「最小尺寸限制」和「Dock 在左」的情况。

### 4.3 App 白名单

`GenericAS.plist`（走通用脚本路径的 App）：
```
com.sony.ebook, com.sonnysoftware.bookends,
com.microsoft.Messenger, Microsoft/com.microsoft.Messenger,
co.hooloovoo.TestWindowGenericAS
```

`ClickToUnmunge.plist`（被鼠标 hack 搞乱后点标题栏可复原的 App）：
```
com.google.picasa, com.eastgate.Tinderbox,
com.bluemangolearningsystems.screensteps3-mac,
co.hooloovoo.TestWindowClickToUnmunge
```

---

## 5. 跨 Space：唯一使用私有 API 的地方

### 5.1 SizeUp 依赖的符号

从 `nm -u MacOS/SizeUp` 提取：

```
_CGSDefaultConnection           获取默认连接
_CGSGetWorkspace                读当前 space 编号
_CGSSetWorkspace                切换当前 space
_CGSMoveWorkspaceWindowList     核心：把窗口送到指定 space
```

相关实例变量/方法：`lionSpacesIDs`、`lionSpaceForSpaceID:`、`lionSpaceIDforSpace:`、`handleSpaceChange:`、`moveWindowToSpace:`、`moveWindowToSpaceDirection:`

### 5.2 前置条件（它做了检测和引导弹窗）

```
Enable Spaces                     Spaces 功能未开启
Enable Spaces Hotkeys             必须先给 Mission Control 的「左/右移一个 Space」设快捷键
Fix Mission Control               必须关闭「自动重新排列 Space」
badMissionControlSetting
IgnoreMissionControlCheck         可跳过检查
Unable to retrieve value for mru-spaces flag.
```

它读 `mru-spaces` 默认值判断「自动重新排列 Space」开关；
切换 Space 靠**模拟 Mission Control 快捷键**；用
`NSWorkspaceActiveSpaceDidChangeNotification` 监听动画结束，带超时
（`Timeout while waiting for Spaces transition to end`）。

限制：
```
Trying to send to invalid space number: %d
Unable to move floating panels between spaces
moveWindowToSpace: Could not get window id, using spaces mouse hack instead.
```

### 5.3 在当前 macOS 上的实测结果

用 `ctypes.CDLL` + 属性访问对两个库做符号探测
（macOS 27.2.1, 26B131, arm64）：

| 符号 | CoreGraphics | SkyLight |
|---|:---:|:---:|
| `_CGSDefaultConnection` | ✅ | ✅ |
| `CGSGetWorkspace` | ✅ | ✅ |
| `CGSGetActiveSpace` | ✅ | ✅ |
| `CGSGetWindowWorkspace` | ✅ | ✅ |
| `CGSMoveWorkspaceWindowList` | ✅ | ✅ |
| `CGSSetWorkspace` | ❌ | ❌ |
| `CGSSetWindowWorkspace` | ❌ | ❌ |
| `SLSCopySpacesForWindows` | ❌ | ✅ |
| `SLSAddWindowsToSpaces` | ❌ | ✅ |
| `SLSRemoveWindowsFromSpaces` | ❌ | ✅ |
| `SLSCopyManagedDisplaySpaces` | ❌ | ✅ |
| `SLSGetActiveSpace` | ❌ | ✅ |
| `SLSManagedDisplayGetCurrentSpace` | ❌ | ✅ |
| `SLSMoveWindowsToSpace` | ❌ | ❌ |

**关键结论：**

1. **`CGSSetWorkspace` 已从系统中消失** → SizeUp 的「切换 Space」功能在新系统上失效。
   这是 2018 年的 App 在当前系统上功能残缺的直接证据。
2. **`SLSMoveWindowsToSpace` 也不存在了** → 不能再用「一步移动」的 API。
3. 可用的新路径是 **SkyLight**：
   ```
   SLSCopySpacesForWindows     找到窗口当前所属 space
   SLSRemoveWindowsFromSpaces  从原 space 移除
   SLSAddWindowsToSpaces       加到目标 space
   SLSCopyManagedDisplaySpaces 枚举所有 space（替代 lionSpacesIDs 的自建表）
   ```
4. **`dlsym` 解析成功只证明符号存在，不证明函数签名和语义未变。**
   必须真机调用验证，且要放在独立模块里可整体禁用。

---

## 6. 动作全集（从 SizeUp.sdef 提取）

### 6.1 枚举（32 个）

```
贴边    Left / Right / Up / Down
象限    Upper Left / Upper Right / Lower Left / Lower Right
整屏    Full Screen / Center
显示器  Prev Monitor / Next Monitor
Space   Space Prev / Space Next / Space Above / Space Below
三分屏  Third Left / Third Center / Third Right
        Third Upper / Third Middle / Third Lower
只移动  Move Left / Move Right / Move Up / Move Down
        Move Upper Left / Move Upper Right / Move Lower Left / Move Lower Right
        Move Center
还原    SnapBack
```

### 6.2 命令（8 个）

```xml
<command name="do action">          执行某个枚举动作
  <parameter name="on monitor">     可选，显示器序号（1-based）
<command name="send to monitor">    送到指定显示器
<command name="send to space">      送到指定 Space
<command name="move to">            移到指定点
<command name="resize to">          调整到指定尺寸
<command name="move and resize to"> 移到并调整到指定矩形（相对显示器）
<command name="fit to grid">        ★ 核心原语
  <direct-parameter>                网格坐标（0-based，6x6）
  <parameter name="grid size">      网格尺寸，默认 6x6
<command name="show menu">          隐藏命令
```

### 6.3 关键洞察

`fit to grid` 的存在证明 **SizeUp 内部只有一个布局原语**：

> **网格选 6×6 不是随意的 —— 6 是 2 和 3 的最小公倍数。**
> 半屏 = 3/6，三分屏 = 2/6，四象限 = 3/6 × 3/6。一个网格容纳所有布局比例。

**复刻时应照此设计**：一张静态表 + 一个通用换算函数，
而不是给 32 个动作各写一遍坐标计算。

---

## 7. 配置格式

### 7.1 `ApplicationOverrides.plist`

```xml
<key>com.irradiatedsoftware.Example</key>
<dict>
  <key>ActionParameters</key>
  <dict>
    <key>Center</key>      <dict><key>Height</key>768 <key>Width</key>1280</dict>
    <key>Full Screen</key> <dict><key>Height</key>-1  <key>Width</key>-1  <key>X</key>-1 <key>Y</key>-1</dict>
    <key>Left</key>        <dict><key>Height</key>-1  <key>Width</key>0.6666 <key>X</key>-1 <key>Y</key>-1</dict>
    <key>Right</key>       <dict><key>Height</key>-1  <key>Width</key>0.6666 <key>X键>0.3333 <key>Y</key>-1</dict>
  </dict>
  <key>Margins</key>
  <dict>
    <key>MarginDown</key>10  <key>MarginLeft</key>100
    <key>MarginRight</key>100 <key>MarginUp</key>-1
  </dict>
</dict>

<key>com.microsoft.Excel.disabled</key>
<dict><key>Margins</key><dict><key>MarginUp</key>33 ...</dict></dict>
```

**两个值得抄的设计：**

1. **`-1` 表示「继承全局默认值」** —— 避免到处判空。
2. **给 key 加 `.disabled` 后缀即可停用该条规则** —— 不用删配置，调试友好。

注意 `Width` 用 `0.6666` 这类**相对比例**（配合设置里的
「Relative to Screen Size」选项），而 `Center` 用绝对像素 `1280x768`。
说明参数支持两种模式。

### 7.2 偏好设置面板（从 Preferences.nib 提取）

6 个标签页（BWToolkit 的 SelectableToolbar）：

```
General          通用
Shortcuts        热键
Partitions       分屏比例（"Quarter Screen Partitions"）
Margins          留白（"Relative to Screen Size"）
Advanced         高级（含 "Multiple Monitor Actions" 分组）
License          授权
```

其它：`Enable Shortcuts`、`Disable Shortcuts in App`、
`Check for Updates Automatically`、`Restore Defaults`。

### 7.3 热键录制

`ShortcutRecorder.framework` + `Localizable.strings` 里的提示：

```
"Click to record shortcut"
"The key combination "%@" couldn't be used, because it's already used by a system-wide keyboard shortcut."
"The key combination "%@" couldn't be used, because it's already used by the menu item "%@"."
"Use old shortcut"
```

> 两种冲突检测都要做：**系统全局热键冲突** 和 **目标 App 菜单项冲突**。

---

## 8. 资源与图标

### 8.1 菜单栏图标三态

每个动作有 3 个变体：

```
align-<action>.png          normal
align-<action>-dark.png     暗色模式
align-<action>-dim.png      不可用（dimmed）
```

覆盖动作：`center, down, fullscreen, left, lowerleft, lowerright,
nextmonitor, prevmonitor, right, snapback, spaceabove, spacebelow,
spacenext, spaceprev, up, upperleft, upperright`

### 8.2 其它资源

- `da-<action>.pdf`（30 个）：偏好设置里快捷键列表的矢量占位图
- `menu.pdf` / `menu_dis.pdf`：菜单示意图
- `pref-{general,shortcuts,partitions,margins,advanced,license}.png`：偏好面板截图
- `SizeUp.icns`（516 KB）、`License.icns`

---

## 9. 对复刻的直接启示

### 必须照抄

| # | 设计 | 理由 |
|---|---|---|
| 1 | **fit-to-grid 作为唯一原语** | 32 动作 = 1 表 + 1 函数，可全部单测 |
| 2 | **6×6 网格** | 2 和 3 的公倍数，容纳半屏/三分屏/四象限 |
| 3 | **设 frame 后回读校验 + 重试** | AX 兼容性的根本 |
| 4 | **按 App override + `.disabled` 后缀** | 配置模型简洁好用 |
| 5 | **Margin 的 `-1` 继承语义** | 避免判空 |
| 6 | **三层降级思路**（AX → AS → 鼠标） | 兼容极端 App |
| 7 | **图标三态**（normal/dark/dim） | 菜单栏体验细节 |
| 8 | **自带 `.sdef`** | 可被 AppleScript 脚本化，自动化价值高 |
| 9 | **热键双冲突检测** | 系统级 + App 菜单级 |

### 必须换掉

| # | 原件 | 替换方案 | 理由 |
|---|---|---|---|
| 1 | `CGSSetWorkspace` 等 CGS API | SkyLight `SLSCopySpacesForWindows` + `SLSAdd/RemoveWindowsFromSpaces` | 旧符号已消失 |
| 2 | `ShortcutRecorder` | `KeyboardShortcuts` | 维护活跃、Swift 原生 |
| 3 | `BWToolkitFramework` | SwiftUI | 已废弃十年 |
| 4 | `CMCrashReporter` | 砍掉 | 自用不需要 |
| 5 | `Sparkle` | 砍掉 | 自用不需要 |
| 6 | x86_64 + i386 | arm64 only | 现代系统 |
| 7 | AppleScript 脚本体系 | 第一版不写，用忽略列表 | 历史包袱，现代 App 大多能响应 AX |
| 8 | Drawer 支持 | 砍掉 | 老式 UI 已淘汰 |

### 值得注意的风险

1. **AX 兼容性无底洞**：SizeUp 为 Office 等 App 写了 14 个脚本 + 按 App 硬编尺寸修正。
   这不是算法问题，是无穷无尽的个案适配。
   → 策略：第一版只做 AX，兼容不了就记录到忽略列表，不做无限投入。
2. **私有 API 会消失**：`CGSSetWorkspace` 的死亡是最好的例子。
   → 策略：跨 Space 做成独立模块 + 默认关闭 + 失败优雅降级。
3. **全屏窗口**：必须先退全屏再设 frame，且要等动画结束（约 0.5s）。
   → 策略：`AXFullScreen = false` 后延迟再设，或轮询状态。
4. **App 会约束修正 frame**（最小尺寸、非零尺寸）。
   → 策略：回读校验，容忍 2px 误差，最多重试 2 次。

---

## 附录：分析命令速查

```bash
# 包结构与签名
plutil -p Contents/Info.plist
codesign -dvvv SizeUp.app
lipo -archs Contents/MacOS/SizeUp
otool -L Contents/MacOS/SizeUp

# 依赖的私有符号
nm -u Contents/MacOS/SizeUp | grep -iE 'CGS|SLS|SkyLight'
nm -u Contents/Frameworks/WindowMover.framework/Versions/A/WindowMover

# 类名与字符串
nm -U Contents/Frameworks/WindowMover.framework/Versions/A/WindowMover
strings -a Contents/Frameworks/WindowMover.framework/Versions/A/WindowMover

# AppleScript 脚本
osadecompile <script>.scpt      # 源码被剥时返回 -1756

# 私有符号是否存在（需在新系统上验证）
python3 -c "
import ctypes
lib = ctypes.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
for n in ['SLSCopySpacesForWindows','SLSAddWindowsToSpaces','CGSSetWorkspace']:
    try: lib[n]; print('OK', n)
    except: print('MISSING', n)
"
```
