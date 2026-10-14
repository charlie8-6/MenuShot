# MenuShot — macOS 菜单栏工具箱

原生 macOS 菜单栏应用（Swift / AppKit + SwiftUI），界面只存在于顶部菜单栏托盘图标中，包含三大功能：**截图**、**Finder 右键新建文件**、**设置**。全程沙盒运行，无后台守护进程、无全局事件监听。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange)

## 功能总览

### 1. 截图
- **多显示器框选**：每个显示器一个覆盖层窗口，正确处理负坐标屏幕（显示器排列在主屏左侧/上方时）；Retina 按 2x 像素裁剪，快照按原始方向渲染（无倒置）。
- **就地编辑（Snipaste/iShot 式）**：拖拽框选 → 选区下方立即浮现完整工具条，无需两段式确认：
  - 工具：钉图、矩形 / 椭圆 / 箭头 / 直线、画笔、文本、颜色（12 色）+ 粗细（1–12）
  - **OCR 文本提取**（Vision，中英文，结果窗可一键复制）
  - **撤销 / 重做**：多步回退（最多 100 步），`⌘Z` / `⇧⌘Z`
  - 保存到默认目录（`⌘S`）/ 另存为（`⇧⌘S`，PNG/JPEG）
  - 「完成」（Enter）：复制到剪贴板，并可按设置同时自动保存
  - **钉图**：合成图悬浮桌面，可拖动、双击关闭、可钉多张
  - 选区本身仍可随时拖动 / 8 向调整大小（工具未激活时）；双击选区 = 完成复制；Esc 逐级退出（工具 → 取消截图）
- **全局快捷键**：默认 `⌥⌘A` 唤起截图，可在设置中录制任意组合（Carbon RegisterEventHotKey，无需辅助功能权限）。

### 2. 创建文件
- 菜单栏「新建文件」子菜单：选择格式 → 选择文件夹 → 创建 `未命名.md`（重名自动 `未命名 2.md`）并在 Finder 中定位。
- **Finder 右键注入**：通过 `FinderSync` 扩展在任意受权目录（含深层子目录、Finder 多窗口）的右键菜单添加「新建文件 → 格式」；右键空白处或选中文件（落到其所在目录）均可使用。
- 内置 9 种格式模板：Markdown / TXT / JSON / YAML / XML / HTML / CSV / Swift / Python。
- 格式的显示名、扩展名、模板内容均可在设置中增删改（支持自定义新格式）。
- **只读目录失败提示**：无写入权限 / 磁盘只读 / 空间不足时给出明确的中文错误弹窗，不静默失败。

### 3. 设置（Tab 栏分区）
- **基础设置**：开机自启动（SMAppService）、截图快捷键录制、确认后自动保存开关、PNG/JPEG 格式、默认保存路径、Finder 扩展状态检测与管理入口、新建文件根目录授权、文件格式列表管理。
- **工具介绍**：功能说明 + **所需权限及申请时机**一览表 + 各系统设置直达按钮 + 版本信息。

## 构建与运行

```bash
# 依赖：Xcode 15+（首次需 xcodebuild -runFirstLaunch），brew install xcodegen
cd MenuShot                # 注意：必须先进入 MenuShot 子目录
xcodegen generate          # 生成 MenuShot.xcodeproj（已预生成，可跳过）
./scripts/build.sh Release # Debug 或 Release

# 运行（在 cTCF 根目录执行时用完整相对路径；构建脚本完成后也会把成品复制一份到 cTCF 根目录）
open .build/Build/Products/Release/MenuShot.app
open ../MenuShot.app       # ← 在根目录直接双击或用这条
```

> 说明：本机无开发者证书，`scripts/build.sh` 采用「编译（跳过签名）→ ad-hoc `codesign` + entitlements」方式签名，本地运行正常。若首次打开被 Gatekeeper 拦截，右键 App → 打开，或 `xattr -cr MenuShot.app`。

## 权限说明（符合沙盒规范）

| 权限 | 用途 | 申请时机 |
|---|---|---|
| 屏幕录制（TCC） | 截取屏幕内容 | **首次点击「截图」时**系统弹窗申请；拒绝时可从弹窗按钮直达系统设置开启 |
| 用户选择的文件（Powerbox） | 新建文件、保存截图、授权根目录 | 每次通过系统「打开 / 保存面板」由用户显式选择时授予，不做静默扫描 |
| App Group 容器 | 主应用与 Finder 扩展共享格式列表、根目录书签 | 沙盒 entitlement 声明（`group.com.cgbin.menushot`） |
| Finder 扩展 | Finder 右键「新建文件」 | 用户在「系统设置 → 隐私与安全性 → 扩展 → 添加的扩展」中**手动启用** MenuShotFinder；设置页有状态检测与直达按钮 |
| 登录项 | 开机自启 | 用户在设置中打开「开机自启动」时注册（SMAppService），可随时关闭 |

不需要「辅助功能」权限（快捷键用 Carbon API），不需要「完全磁盘访问」。

### Finder 扩展启用步骤
1. 打开 MenuShot → 设置 → 基础设置 →「新建文件」
2. 点击「管理扩展…」→ 勾选 **MenuShotFinder**
3. 点击「选择根目录…」授权一个根目录（建议个人主目录），其下任意层级文件夹的右键菜单即出现「新建文件」

## 架构

```
MenuShot.app
├── MacOS/MenuShot                 主应用（菜单栏，LSUIElement 无 Dock 图标）
└── PlugIns/MenuShotFinder.appex   Finder Sync 扩展（右键新建文件）

Sources/
├── App/                主应用
│   ├── main.swift / AppDelegate.swift      入口、状态栏菜单、分布式通知监听
│   ├── ScreenshotCoordinator.swift         截图编排：权限→多屏快照→覆盖层→编辑器
│   ├── SelectionOverlay.swift              框选覆盖层（负坐标/移动/8向调整）
│   ├── EditorCanvasView.swift              标注画布：图形/画笔/文本/多步撤销重做/合成输出
│   ├── EditorController.swift              编辑窗口 + 浮动工具条 + OCR 结果窗
│   ├── OCRService.swift                    Vision 文字识别（zh-Hans + en-US）
│   ├── PinWindow.swift                     钉图悬浮窗（多实例管理）
│   ├── SaveService.swift                   默认目录/另存为（安全作用域书签）
│   ├── NewFileService.swift(Shared)        重名避让/模板写入/只读错误转换
│   ├── AppSettings / SettingsView.swift    SwiftUI 双 Tab 设置 + 快捷键录制器
│   └── HotKeyCenter.swift                  Carbon 全局快捷键
├── FinderSync/         扩展：注入「新建文件」菜单 + 创建回传
└── Shared/             主应用/扩展共享：App Group 配置、格式模型、建文件逻辑
```

**扩展 ↔ 主应用协作（v2 架构）**：扩展只负责菜单展示，点击后把「创建请求」（目标目录 + 扩展名）写入 App Group 共享容器并发信号通知；由**常驻主应用**执行实际写文件——它持有用户授权的安全作用域书签，写权限必然有效，从根本上避免扩展进程书签解析失败导致的「点击创建失败」。主应用离线时扩展会在 3.5s 后兜底自行创建。授权根目录变更通过分布式通知热刷新扩展监听，无需重启 Finder。

## 质量说明
- **启动/响应**：无 XIB/资源预载，启动即挂状态栏图标（冷启动 < 0.3s），实测常驻内存 ≈ 18 MB。
- **动画**：覆盖层淡入、编辑器/工具条/钉图/Toast 淡入淡出 + 缓动（NSAnimationContext）。
- **内存**：快照即用即放；覆盖层窗口用后销毁；撤销栈上限 100 步。
- **不侵入**：无 LaunchAgent/守护进程、无键盘鼠标全局监听、所有文件访问走 Powerbox 授权。

## 常见问题排查
- **菜单栏找不到图标**：图标是右上角的粗线条取景框（自绘 template，随明暗模式变色）；应用启动约 1 秒后会弹 Toast 提示位置。进程存活但找不到时，检查菜单栏是否被大量图标挤占（系统会自动隐藏溢出图标）。
- **启动台没有图标**：应用必须位于 `/Applications`（或 `~/Applications`）才会进启动台，`./scripts/build.sh` 已自动安装到 `/Applications`。
- **右键创建失败**：设置页「扩展实际监听」显示扩展侧自检结果；新架构下写文件由主应用执行，若仍失败请看错误弹窗中的具体原因（无权限 / 磁盘只读等）。
- **重新构建后截图权限失效**：TCC 按签名跟踪授权，重签后需重新允许，或 `tccutil reset ScreenCapture com.cgbin.menushot` 重置。

## 已知限制
- 框选每次限定单个显示器内（跨屏框选是业界普遍做法的限制）。
- 无付费开发者团队签名时，每次重新构建后需重新授予「屏幕录制」权限（TCC 以签名为准）；可用 `tccutil reset ScreenCapture com.cgbin.menushot` 重置。
- Finder 扩展菜单项由系统渲染，嵌套层级因 macOS 版本略有差异（应用分组下显示「新建文件」子菜单）。
