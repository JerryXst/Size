# Size

macOS 窗口管理工具，复刻 [SizeUp](https://sizeup.macupdate.com/) 的体验，用现代 Swift 重写。

- `SizeCore` — 纯逻辑：网格换算、34 个动作、配置、热键定义（可单测，无 UI 依赖）
- `SizeAX` — 公开 Accessibility API 封装：枚举窗口、读写 frame、回读校验
- `SizeSpaces` — 跨 Space（SkyLight 私有 API，默认关闭，失败可整体禁用）
- `SizeApp` — AppKit 菜单栏 App + SwiftUI 设置界面
- `size-cli` — 命令行工具，用于脚本化和验证

设计规格见 [DESIGN.md](DESIGN.md)，SizeUp 逆向分析见 [docs/sizeup-analysis.md](docs/sizeup-analysis.md)。

---

## 当前状态

| 里程碑 | 状态 |
|---|---|
| M0 授权 / 枚举 / 改 frame | ✅ 真机验证 |
| M1 fit-to-grid + 34 动作 + 单测 | ✅ 82 个单测通过，0 编译警告 |
| M2 菜单栏 + 全局热键 + 忽略列表 | ✅ 18 个热键，菜单可展开 |
| M3 Margin / gap / per-App override / 网格配置 | ✅ 可用 |
| M4 回读校验 / 重试 / 全屏退出 / SnapBack / 跨显示器 | ✅ 满屏跨屏吸附已修 |
| M5 跨 Space | 🟡 已实现，默认关闭 |
| 设置界面 / 快捷键录制 / 开机自启 | ✅ |

---

## 构建与安装

```sh
cd /Users/jerryxst/Code/Github/Size
bash Scripts/build-app.sh          # 产出 build/Size.app
open build/Size.app                # 启动（菜单栏出现图标，无 Dock 图标）
```

`swift build` / `swift test` 可单独跑，不需要打包。

---

## 签名：这一节请务必读

这个 App 需要**辅助功能（Accessibility）权限**，而 macOS 把这项授权绑在**代码签名身份**上。签名方式选错会踩两个坑：

### 坑一：ad-hoc 签名 → 每次重建都掉权限

用 `codesign -s -`（ad-hoc）签名时，每次重新编译签名都变，macOS 认作一个全新的 App，**之前授予的辅助功能权限全部失效**。

表现就是：明明授权过了，热键却「有时灵有时不灵」，或者「只对某个 App 有效」。

### 坑二：用 Apple 开发证书 → 证书被吊销后 Gatekeeper 直接判定恶意软件

如果脚本回退去用机器上任意一张 `Apple Development` 证书，而那张证书**已被吊销**，`spctl` 会返回：

```
CSSMERR_TP_CERT_REVOKED
```

此时 macOS 会弹「**已阻止恶意软件并移到废纸篓**」，App 根本无法启动。
**被吊销的证书比 ad-hoc 还糟**——ad-hoc 至少能启动。

### 正确做法：本地自签名证书（一次性）

```sh
bash Scripts/make-signing-identity.sh    # 创建 "Size Dev" 自签名证书
bash Scripts/build-app.sh                 # 之后自动用它签名
```

`Size Dev` 是本地自签名证书，**永不过期、不会被吊销**，签名身份稳定，
所以辅助功能授权可以**跨重建保留**，只需要授权一次。

> `build-app.sh` 已经**不再回退到任意 Apple 开发证书**，并且会在签名后跑
> `codesign --verify` 和 `spctl`，一旦证书被吊销会直接报错退出，
> 不会让你踩到「恶意软件」弹窗。

`spctl` 对自签名 App 显示 `rejected` 是**正常的**（没有公证），不影响本地运行。

---

## 验证

```sh
bash Scripts/verify.sh
```

依次检查：

0. 包构建 + 签名有效性 + 是否只有一个实例在跑（多实例会抢热键）
1. 82 个单元测试
2. 端到端：对一个一次性测试窗口应用全部动作
3. 真实按键事件驱动运行中的 App
4. 设置窗口能打开且有控件
5. 清理残留 LaunchAgent

> **锁屏时会自动跳过第 2~4 步**：macOS 不允许在锁屏状态下跨 App 操作窗口，
> 这时 AX 会返回降级数据（拿到的不是窗口而是应用元素），任何工具都无法工作。
> 解锁后重跑即可。

单测不需要任何权限，随时可跑：

```sh
swift test
```

---

## 用法

菜单栏图标 → 选动作；或直接按热键。

| 热键 | 动作 |
|---|---|
| `⌃⌥←/→/↑/↓` | 左/右/上/下半屏 |
| `⌃⌥U/I/J/K` | 四象限 |
| `⌃⌥↩` | 铺满可见区 |
| `⌃⌥D/F/G` | 左/中/右三分之一 |
| `⌃⌥C` | 居中 |
| `⌃⌥,` / `⌃⌥.` | 上一台 / 下一台显示器 |
| `⌃⌥⌫` | 撤销上一次布局（SnapBack） |

命令行（通过进程间通道驱动运行中的 App）：

```sh
size-cli list                          # 列出可控窗口
size-cli apply --pid 123 --action left # 对指定窗口执行动作
size-cli action left                   # 对当前焦点窗口执行动作
size-cli action fullScreen --pid 123   # 指定目标
```

> CLI **不自己移动窗口**。裸命令行工具没有独立的辅助功能授权，
> AX 会返回降级数据（`kAXSubrole` 报 unsupported，拿到的是应用元素而非窗口）。
> 所以 CLI 通过分布式通知把请求交给 App，由持有授权的 App 执行并记录结果。

配置与日志：

- 配置：`~/Library/Application Support/Size/config.json`
- 动作日志：`~/Library/Logs/Size/actions.log`

---

## 满屏跨屏保持满屏

从 A 屏移到分辨率不同的 B 屏时：

- 窗口原本**铺满** A 屏（含多屏拼合）→ 移到 B 屏后铺满 B 屏
- 否则按**真实比例**映射，保持相对大小和位置
- 判断「算满屏」有 8pt 容差，因为不同屏幕的菜单栏高度不同，
  所谓满屏窗口常常差几个点没贴边

---

## 已知限制

- 只处理 `kAXStandardWindow` 标准窗口，对话框 / 浮动面板有意排除
- 永远不操作自身进程
- 只支持 AX：对拒绝或强制修正 frame 的 App，重试 3 次后放弃
- 原生全屏窗口先退出全屏（等 0.5s 动画）再设置 frame
- 跨 Space 依赖私有 API，系统更新可能失效，默认关闭
- 锁屏状态下无法跨 App 操作窗口（系统限制，不是 bug）
- 未做公证，`spctl` 判定 `rejected` 属正常

---

## 踩坑记录（新环境必看）

1. **macOS 27 起 `import Foundation` 不再隐式带出 CoreGraphics** —— 用到 `CGRect`
   的文件必须显式 `import CoreGraphics`，否则报 `CGRect has no member minX`。
2. **`kAXFullScreenAttribute` 在公开 API 里不存在** —— 用字符串 `"AXFullScreen"`。
3. **`set -o pipefail` + `grep -q`** —— grep 提前退出会让上游收到 SIGPIPE，
   管道返回 141，把通过的测试误判为失败。先写文件再 grep。
4. **签名证书被吊销**会让 Gatekeeper 把 App 当恶意软件移进废纸篓，详见上文。
5. **多实例会抢热键** —— 两个实例各自注册同一批热键，按键落到错误的那个上。
   启动时有单实例守卫，但仍要确认只有一个在跑。
6. **不要用 `--options runtime`**（硬化运行时）配本地证书 —— launchd 会拒绝启动
   （`RBSRequestErrorDomain Code=5`, POSIX 163）。
