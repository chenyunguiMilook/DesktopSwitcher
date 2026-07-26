# Desktop Switcher

macOS 悬浮小组件，横向列出当前显示器的所有桌面（Space），点击即切换。

```
[1] 2  3  4  5  +
```

## 为什么做这个

远程控制另一台 Mac 时，**切换桌面的手势用不了**。

三指左右滑、`⌃←` / `⌃→`、Mission Control 手势 —— 这些都依赖本机的触控板或键盘。
一旦你是通过屏幕共享、VNC、向日葵之类的工具去操作远端那台 Mac，手势不会被转发过去，
键盘快捷键也常被本地系统先吃掉。结果就是：远端明明开了好几个桌面，你却只能困在其中一个。

这个小组件常驻在远端桌面上，用**鼠标点一下数字**就能切换。鼠标事件是远程控制唯一能可靠转发的东西，
所以这条路是通的。

顺带也适合这些场景：触控板坏了、用外接鼠标不想记快捷键、或者只是想一眼看到"我现在在第几个桌面"。

## 安装

需要 macOS 14 以上、Xcode 命令行工具。

```bash
git clone https://github.com/chenyunguiMilook/DesktopSwitcher.git
```

```bash
cd DesktopSwitcher && ./build.sh --install
```

首次点击桌面时会弹出辅助功能授权请求，授权后即可使用。组件无 Dock 图标，右键菜单里可以退出。

## 使用

| 操作 | 效果 |
|---|---|
| 点击数字 | 切换到该桌面 |
| 点击末尾 `+` | 新建桌面 |
| **右键点数字** | 该桌面的菜单：切换到桌面 N / **删除桌面 N** |
| 右键点背景 | 全局菜单：锁定位置、开机启动、授予权限、重置位置、退出 |
| 拖动组件背景 | 移动位置，自动记住 |

`⌃` 点击等同右键。橙色小圆点表示尚未获得辅助功能权限；授权后消失。

### 自动淡出

闲置 4 秒后组件淡到 40% 透明度，不再抢注意力，但仍能一眼看出当前在第几个桌面。

唤醒要求**指针停留** 0.5 秒 —— 单纯滑过不会让它亮起来，这样它就不会在你把鼠标移向别处时反复闪。
点击、拖动、右键则立即唤醒，那时意图很明确。

判定悬停用的是**轮询光标真实位置**（每 0.2 秒一次），不是 tracking area 的 enter/exit 事件。
后者不可靠：布局变化时重装 tracking area 会产生一对虚假的 exit/enter，而一个没有配对 exit 的
假 enter 会把组件永久锁在不透明状态。光标位置不可能失同步，状态机因此可以自愈；
同时也不干扰 SwiftUI 自己的悬停追踪（按钮的高亮靠它）。

- 组件在每个桌面都可见，不随切换动画滑动，点击不抢当前 App 的焦点。
- 只显示普通桌面，全屏应用和分屏组合会被过滤掉。
- 编号是 Mission Control 里的左右顺序，和系统的"桌面 N"一致。
- 删除桌面**不会关闭窗口** —— 上面的窗口会移到相邻桌面，这是 macOS 的行为。
- 只剩一个桌面时"删除"置灰；达到系统桌面数上限时点 `+` 无效果。
- 单次切换约 300ms（Mission Control 冷启动时约 700ms），期间 Mission Control 会一闪。

## 实现：为什么是这条路

切换桌面在 macOS 26 上没有干净的做法。三条路里两条是死的，实测记录如下。

### ✗ 私有 CGS/SkyLight 写入 API —— 只改记账，不动画面

以低分辨率屏幕截图作为客观基准（噪声基线 0.00），9 条路径全部无效：

```
route                                 reported    pixel diff  verdict
SLSManagedDisplaySetCurrentSpace      switched    0.00        no visual change
SLSTransactionSet… + Commit(async)    switched    0.00        no visual change
SLSTransactionSet… + Commit(sync)     switched    0.00        no visual change
ShowSpaces + set + HideSpaces         switched    0.00        no visual change
move window to space + activate       unchanged   0.00        no visual change
RequestSwitchToSpaceForWindow ×3      unchanged   0.00        no visual change
EnsureSpaceSwitchToActiveProcess      unchanged   0.00        no visual change
```

符号全部存在（SkyLight 导出 1580 个 `SLS*`，256 个与 Space 相关），调用也不报错，
但它们只更新 WindowServer 的内部记账 —— 调用后 `SLSGetActiveSpace()` 会与屏幕内容**失同步**。
因此本项目只用 CGS **读取**桌面拓扑，不做任何写入。

复验：`swiftc -O Tools/cgs-probe.swift -o /tmp/cgs-probe && /tmp/cgs-probe`

### ✗ 合成 ⌃←/⌃→ 按键 —— 被 WindowServer 在快捷键匹配前丢弃

| 测试 | 结果 |
|---|---|
| 辅助功能权限 | ✅ 已授权 |
| 事件进入系统 HID 流 | ✅ 自装 event tap 观测到，flags 含 Control |
| Secure Input 屏蔽 | ✅ 无进程持有 |
| 普通按键投递到 App 输入框 | ✅ 成功 |
| ⌃→ / ⌃↑ / ⌘Space 等系统快捷键 | ❌ 全部无反应 |

合成事件能送达普通 App，但**所有系统快捷键都不响应** —— 连 Spotlight 都打不开。
WindowServer 内部的 `CGXSenderCanSynthesizeEvents()` 会区分真实硬件事件和 `CGEventPost`，
在快捷键匹配**之前**就把后者丢掉。参见
[Nick Liu 的实测记录](https://www.nick-liu.com/posts/tahoe-hotkey-dead-end/)（同为 macOS 26.5）。

这也解释了生态现状：[AeroSpace](https://github.com/nikitabobko/AeroSpace) 干脆完全不用原生 Spaces、
自己模拟工作区；[yabai](https://github.com/koekeishiya/yabai) 要操作 Spaces 就必须关闭 SIP 并注入 Dock.app。

### ✓ Mission Control 的空间栏 + 辅助功能动作

关键点：**AX 动作不是合成事件**。`AXPress` 是发给 Dock 进程的直接消息，不受上面那个过滤器影响。
而 Mission Control 本身是个真实 App bundle，`open -g` 打开它也不需要合成任何事件。

Dock 的辅助功能树里：

```
role=AXGroup title="空间栏"
  role=AXList
    role=AXButton title="桌面1" desc="退出到“桌面1”" actions=["AXPress", "AXRemoveDesktop"]
    role=AXButton title="桌面2" ...
  role=AXButton desc="添加桌面" actions=["AXPress"]
```

- 切换 = `AXPress` 缩略图
- 删除 = 缩略图自带的 `AXRemoveDesktop`
- 新建 = 空间栏里的"添加桌面"按钮（结构上是 `AXList` 的兄弟节点）

代码靠这些**动作名和结构位置**定位元素，不靠 `"桌面N"` 这类会随系统语言变化的标题。

### 两个踩过的坑

**1. 按早了会被静默吞掉，而且 Mission Control 还是会关闭。**
缩略图在 MC 动画完成前就能通过 AX 访问到，此时按下无效。更麻烦的是没有几何信号可用 ——
缩略图出现后位置尺寸恒为 `(798, -32)` / `37×24`，**从不变化**（Tahoe 的空间栏是折叠的），
所以"等坐标稳定"这种判断毫无意义。唯一可信的信号是**动作有没有生效**：
切换改成按下 → 校验 `SLSGetActiveSpace` → 没变就再按，并在被吞掉导致 MC 关闭时重新打开它。

因为每次按的都是同一个目标桌面，重复按是幂等的。但**新建和删除不幂等** —— 按两次会多建/多删一个，
所以那两个操作只按一次，用较长的固定延迟保证首次按下被接受。

**2. 不能每轮轮询都请求打开 Mission Control。**
`open -a "Mission Control"` 是 toggle。早期版本在缩略图未出现时每 50ms 调一次，
于是 MC 被反复开关、永远稳不下来 —— 压力测试里前 5 次切换全失败，之后 MC 恰好停在打开状态才开始正常。
现在每 1.2 秒最多请求一次，这个间隔必须大于空间栏出现所需的 ~450ms。

修复后压力测试 **14/14 通过，0 失败，平均 298ms**。

## 项目结构

```
Sources/DesktopSwitcher/
  main.swift                 入口，LSUIElement 无 Dock 图标
  AppDelegate.swift          面板装配、几何、右键菜单
  CGS/
    SkyLight.swift           dlsym 解析私有符号，只绑读取入口
    SpaceReader.swift        拓扑解析、显示器 UUID 匹配
    SpaceSwitcher.swift      Mission Control 空间栏：切换 / 删除 / 新建
  Model/
    SwitcherModel.swift      @Observable 状态，变化时才发布
    SpaceMonitor.swift       通知 + 1.5s 低频轮询
  UI/
    FloatingPanel.swift      NSPanel：非激活、全 Space 可见、可拖动
    SwitcherView.swift       SwiftUI 胶囊行 + 末尾 "+"
    SwitcherMetrics.swift    布局常量，视图与右键命中测试共用
    SwitcherHostingView.swift  acceptsFirstMouse + 按胶囊分派右键菜单
  Support/
    Preferences.swift        位置持久化、锁定、开机启动
Tools/cgs-probe.swift        私有 API 可行性探针
docs/superpowers/specs/      设计文档与完整实测数据
```

## 关于"授权了还一直弹"

TCC 把辅助功能授权绑定在**代码签名的指定要求**上。ad-hoc 签名的要求串里含 cdhash，
二进制一变就对不上，于是每次重新构建授权都作废。

`build.sh` 因此自动挑一个稳定证书（优先 `Developer ID Application`，其次 `Apple Development`），
签出来的要求不含 cdhash，**重新构建不会再让授权失效**。找不到证书才回退 ad-hoc 并打印警告。
要指定证书：`CODESIGN_IDENTITY="证书名称" ./build.sh --install`

换过签名方式之后，macOS 会把已有授权重置为拒绝，条目通常还在列表里、只是开关被关掉，打开即可。
查当前状态（`auth_value`：0 拒绝 / 2 允许）：

```bash
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select client, auth_value from access where service='kTCCServiceAccessibility' and client like '%desktopswitcher%';"
```

只有当 `csreq` 里的 `subject.OU` 与当前签名 Team ID 对不上时，才需要
`tccutil reset Accessibility com.chenyungui.desktopswitcher`。

## 已知限制

- **切换时 Mission Control 会一闪**，无法消除：转场由 Dock 独占。
  `SLSSpaceGetAlpha` / `GetAbsoluteLevel` / `GetRect` 对当前与非当前 Space 返回完全相同的值
  （`1.0` / `0` / 空矩形），连"系统如何表示某个 Space 可见"都读不到，更无从设置。
  开启**系统设置 → 辅助功能 → 显示 → 减弱动态效果**可以把缩放换成交叉淡入淡出，主观上柔和些。
- **多显示器只做了显示侧的区分。** 组件显示它所在那块屏幕的桌面（按显示器 UUID 匹配，可靠）；
  但按缩略图时无法按屏幕筛选空间栏 —— 缩略图的 AX 坐标在屏幕外（y = -32），
  位置匹配永远落空、总是回退到"全部缩略图"。多显示器环境下的增删改行为未经验证。
- 使用私有 API，无法上 Mac App Store。
- 只在 macOS 26.5 (Tahoe) 上验证过。

## 验证记录

- 构建零警告；空闲 CPU 0.0%，常驻内存 ~49MB
- 切换：压力测试 14/14 通过、0 失败，平均 298ms（min 280 / max 336）
- 切换到全部 5 个桌面各一次、起点各不相同，`ManagedSpaceID` 与索引一一对应，高亮每次跟随
- 新建：5 → 6 正确追加；删除：6 → 5 正确移除；往返测试后桌面数还原
- 右键命中测试 18/18：内边距、胶囊间隙、上下边缘、`+` 区域都正确不命中桌面
- 自动淡出：以 `kCGWindowAlpha` 客观读取，闲置后 1.0 → 0.40；指针进入时**仍保持 0.40**、
  停留约 0.5s 后升到 1.00；指针离开后自行回落到 0.40
- Mission Control 操作后正常关闭，未残留
- 位置持久化（含首次启动，按 `visibleFrame` 居中，已排除侧边 Dock 影响）
- 浅色 / 深色两种外观渲染
- 重新构建后辅助功能授权保留（签名要求串不变）
- 探针 9 条路径结果可复现

## License

MIT
