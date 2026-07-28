# Mac Floating Desktop Switcher — 设计文档

日期：2026-07-26
平台：macOS 26.5 (Tahoe) / Swift 6.3 / Xcode 26.6

## 1. 目标

一个常驻悬浮的极简小组件，横向列出当前显示器的所有桌面（Space），高亮当前桌面，点击即切换。启动后几乎无感，资源占用极低。

非目标：窗口管理、Stage Manager、全屏应用管理。

> 2026-07-26 追加：用户后续要求支持删除与新建桌面，原非目标「不创建或删除 Desktop」已作废。
> 两者都复用 Mission Control 空间栏的 AX 能力（缩略图自带 `AXRemoveDesktop`，空间栏内另有"添加桌面"按钮）。

## 2. 关键调研结论（决定架构）

原始需求要求用 `CGSManagedDisplaySetCurrentSpace()` 切换 Space，且不依赖辅助功能或键盘模拟。**实测证明这条路在 macOS 26 上不可用。**

### 实验方法

以低分辨率（64×36 灰度）屏幕截图指纹作为"画面是否真的变了"的客观基准，
对比 `SLSGetActiveSpace()` 报告的状态。噪声基线（同一 Space 间隔 1.5 秒截两次）为 `0.00`。

### 实验结果

| 策略 | `SLSGetActiveSpace` | 像素差异 | 结论 |
|---|---|---|---|
| `SLSManagedDisplaySetCurrentSpace` | 报告已切换 | **0.00** | 画面未动 |
| `SLSTransactionSetManagedDisplayCurrentSpace` + `Commit(0)` | 报告已切换 | **0.00** | 画面未动 |
| 同上，`Commit(1)` 同步提交 | 报告已切换 | **0.00** | 画面未动 |
| `SLSShowSpaces` + 设置 + `SLSHideSpaces` | 报告已切换 | **0.00** | 画面未动 |
| 窗口移到目标 Space (`SLSMoveWindowsToManagedSpace`) 后激活（`.accessory` + 1×1 窗口） | 未切换 | **0.00** | 画面未动 |
| 同上，`.regular` 策略 + 420×300 真实窗口 | 未切换 | **0.00** | 画面未动 |

符号本身全部存在（SkyLight 导出 1580 个 `SLS*` 符号，256 个与 Space 相关），调用也不报错——
它们只更新 WindowServer 的内部记账，不驱动实际合成输出。

### 解读

这与 yabai 必须关闭 SIP、把脚本插件注入 Dock.app 才能切换 Space 的事实一致：
**真正的 Space 切换必须由 Dock 进程发起**，普通进程即使调用同名私有 API 也只能改状态位。

更糟的是，调用这些 API 会让 `SLSGetActiveSpace()` 与实际画面**失同步**，属于有害副作用。
因此本项目**不使用**这些写入型 API。

### 第二次尝试：合成 ⌃←/⌃→ 按键 —— 同样失败

| 测试 | 结果 |
|---|---|
| 辅助功能权限 | ✅ `auth_value=2`，`AXIsProcessTrusted()=true` |
| 事件进入系统 HID 流 | ✅ 自装 event tap 观测到，flags 含 Control |
| Secure Input 屏蔽 | ✅ 无进程持有 |
| 普通按键投递到 App 输入框 | ✅ "a" 成功进入文本框 |
| ⌃→ 切换桌面 / ⌃↑ Mission Control / ⌘Space Spotlight | ❌ 全部无反应 |
| 直接 `postToPid` 给 Dock、App 处于最前台时再发 | ❌ 无反应 |

合成事件能送达普通 App，但**所有系统快捷键都不响应**。WindowServer 内部的
`CGXSenderCanSynthesizeEvents()` 在快捷键匹配前就丢弃 `CGEventPost` 事件。

### 最终方案：Mission Control + AX 动作

AX 动作（`AXPress`）是发给 Dock 进程的**直接消息，不是合成事件**，不受上述过滤器影响。
Mission Control 是真实 App bundle，`open -g` 打开它也无需合成事件。

Dock 辅助功能树中：

```
role=AXGroup title="空间栏"
  role=AXList
    role=AXButton title="桌面N" desc="退出到“桌面N”" actions=["AXPress", "AXRemoveDesktop"]
```

用 `AXRemoveDesktop` 动作定位缩略图（语言无关），按索引 `AXPress`。

**实测**：5 个桌面各切换一次，起点各不相同，全部成功，`ManagedSpaceID` 与索引一一对应
（`[3,1,6,4,5]`），高亮每次跟随，Mission Control 每次正常关闭。

一个关键实现细节：缩略图在 Mission Control **动画完成前**就能通过 AX 访问到，
此时按下会被静默忽略。因此需要「发现缩略图 → 等动画停稳 → 按下 → 0.7s 后校验
`SLSGetActiveSpace` → 未变则重试一次 → 仍失败则关闭 MC」。少了沉降就会出现
偶发不切换、且把 Mission Control 留在屏幕上的问题。

"等动画停稳"最初是固定 0.35s，后改为每 20ms 读缩略图 `AXPosition`、直到两次读数相同。
**这是个错误的优化**：缩略图出现后位置尺寸恒为 `(798, -32)` / `37×24`，从不变化，
所以稳定性判断在第二次采样（~37ms）就通过，等于在动画中途按下 —— 造成间歇性"有动画但不切换"。
而被吞掉的按下仍会关闭 Mission Control，导致后续重试找不到缩略图而放弃。

最终改为**按下-校验-重按**：唯一可信的就绪信号是动作有没有生效。切换是幂等的（每次都按同一个
目标桌面），可以放心重按；新建/删除不幂等，只按一次并用较长固定延迟。

还有一个更严重的 bug：`open -a "Mission Control"` 是 toggle，早期重试循环在缩略图未出现时
每 50ms 请求一次，导致 MC 被反复开关、永远稳不下来（压力测试前 5 次全失败）。
改为每 1.2s 最多请求一次，该间隔必须大于空间栏出现所需的 ~450ms。

修复后压力测试 14/14 通过、0 失败、平均 298ms。

### 为什么无法做到无动画

剩余 ~690ms 全是 Mission Control 自身的开合动画，无法消除：

- 9 条 CGS 写入路径都不驱动画面（见上）。
- `SLSSpaceGetAlpha` / `SLSSpaceGetAbsoluteLevel` / `SLSSpaceGetRect` 对当前 Space 与
  非当前 Space 返回**完全相同**的值（`1.0` / `0` / 空矩形）。这些是本连接的私有覆盖值，
  读不到 Dock 的实际合成状态，因此"设置 alpha/reveal 来手动切换"的思路也不成立。
- Dock 的 `expose-animation-duration` 偏好实测对本路径无影响（1123ms vs 基线 1112ms）。

用户侧唯一的缓解手段是开启「减弱动态效果」，把缩放换成交叉淡入淡出。

### 架构后果

- **读取**走 CGS 私有 API（`SLSCopyManagedDisplaySpaces`），完全可靠。
- **切换**走 Mission Control + AXPress，需要辅助功能授权。这偏离了原需求的
  "不依赖 Accessibility"，但那是当前 macOS 上唯一可行的路径。
- 代价：切换时 Mission Control 会短暂出现。
- 探针工具保留在 `Tools/cgs-probe.swift`，未来 macOS 版本可复验，一旦 Apple 放开私有 API 就能切回。

## 3. 架构

```
DesktopSwitcher.app  (LSUIElement，无 Dock 图标)
│
├── CGS 层（只读）
│   ├── SkyLight.swift        dlsym 解析私有符号；缺符号则降级而非崩溃
│   └── SpaceReader.swift     解析显示器/Space 拓扑，过滤出 type==0 的桌面
│
├── 切换层
│   └── SpaceSwitcher.swift   Mission Control 空间栏：切换 / 删除 / 新建
│
├── 模型层
│   ├── SwitcherModel.swift   @Observable 状态；panel 所在屏幕 → 对应显示器
│   └── SpaceMonitor.swift    activeSpaceDidChange + 屏幕变更 + 低频轮询
│
└── UI 层
    ├── FloatingPanel.swift   NSPanel：非激活、全 Space 可见、可拖动
    ├── SwitcherView.swift    SwiftUI 胶囊行 + 末尾 "+" 按钮
    ├── SwitcherMetrics.swift 布局常量，视图与右键命中测试共用同一份
    └── SwitcherHostingView.swift  acceptsFirstMouse + 按胶囊分派右键菜单
```

### 数据流

```
定时器 / activeSpaceDidChange / 屏幕变更
        └─> SwitcherModel.refresh()
              └─> SpaceReader.read()  ← SLSCopyManagedDisplaySpaces
                    └─> 按 panel 所在屏幕的 display UUID 过滤
                          └─> 仅在内容变化时赋值（避免无谓重绘）
                                └─> SwiftUI 更新

点击第 N 个胶囊
        └─> SpaceSwitcher.switch(to: N)
              ├─ 无辅助功能授权 → 返回 .needsAccessibility → 弹引导
              └─ 有授权 → open -g Mission Control
                            → 轮询 Dock AX 树直到"空间栏"缩略图出现
                              → 沉降 0.35s → AXPress 第 N 个
                                → 0.7s 校验，未切换则重试一次
```

### 关键设计点

**显示器归属**：面板中心所在的 `NSScreen` → `CGDisplayCreateUUIDFromDisplayID` → 与
`SLSCopyManagedDisplaySpaces` 返回的 `Display Identifier` 匹配。拖到另一块屏幕自动切换数据源。
这是**读取侧**，可靠。

> 修正（2026-07-26）：按缩略图坐标筛选屏幕**并未生效** —— 折叠状态下缩略图恒为 y = -32。
>
> 再修正（2026-07-28）：接上 3 块显示器后重测，发现**父级空间栏**的坐标是可用的
> （`bar[0] pos=(0,0)` 对应主屏，`bar[1] pos=(620,1269)` 对应第二块屏）。
> 已改为按空间栏分组、用栏位置匹配显示器，多显示器下的索引错位因此修复。

**桌面编号**：`Spaces` 数组顺序即 Mission Control 里的左右顺序，`index + 1` 就是"桌面 N"。
不使用 `ManagedSpaceID`（它是不连续的内部 ID，本机实测为 `[3, 1, 6, 4, 5]`）。

**面板行为**：`.nonactivatingPanel` 保证点击不抢焦点；`.canJoinAllSpaces + .stationary`
保证每个桌面都能看到且不随桌面滑动。

**刷新策略**：`activeSpaceDidChangeNotification` 提供即时响应；1.5 秒低频轮询兜底捕获
"桌面数量变化"（增删桌面不发通知）。轮询只做一次廉价 IPC + 结构体比较，无变化不触发重绘。

## 4. 错误处理

| 情况 | 行为 |
|---|---|
| SkyLight 打不开 / 符号缺失 | 面板显示"不可用"占位，不崩溃 |
| 无辅助功能授权 | 点击时弹系统授权引导；胶囊显示为待授权样式 |
| 面板所在屏幕无匹配显示器 | 回落到第一个显示器 |
| 桌面数为 0 或 1 | 正常显示；只剩一个时"删除"置灰 |
| 达到桌面数上限 | Dock 隐藏"添加桌面"按钮，代码找不到目标则关闭 MC 后静默返回 |
| 屏幕拔插导致位置越界 | 启动/屏幕变更时把面板夹回可见区域 |

## 5. 测试

- `Tools/cgs-probe.swift`：独立可执行探针，复验 9 条 CGS 路径与符号可用性。
- 切换验证：5 个桌面各切一次、起点各不同，核对 `ManagedSpaceID` 与索引映射、高亮跟随、
  Mission Control 是否残留。
- 其余已验证项与待人工确认项见 README「验证记录」。

## 6. 已知偏离

- 原需求「使用 `CGSManagedDisplaySetCurrentSpace()` 切换」**无法满足** —— 该 API 及其
  8 个同类路径在 macOS 26 上都不驱动画面。
- 原需求「无需依赖 Accessibility」**无法满足** —— 唯一可行的切换途径是 AX 动作。
- 原非目标「不创建或删除 Desktop」已按用户后续要求作废，两者均已实现。
- 切换时 Mission Control 会短暂出现，不是完全无感。

其余需求全部实现并验证。
