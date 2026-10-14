import AppKit
import SwiftUI
import FinderSync

/// 设置窗口（承载 SwiftUI 内容）
final class SettingsWindowController: NSWindowController {

    enum Tab: Int {
        case general = 0
        case about = 1
    }

    static let shared = SettingsWindowController()

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "MenuShot 设置"
        window.titlebarAppearsTransparent = false
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsRootView(initialTab: .general))
    }

    func show(tab: Tab) {
        guard let window = window else { return }
        (window.contentView as? NSHostingView<SettingsRootView>)?.rootView = SettingsRootView(initialTab: tab)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsRootView: View {
    @State private var selection: Int

    init(initialTab: SettingsWindowController.Tab) {
        _selection = State(initialValue: initialTab.rawValue)
    }

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .tabItem { Label("基础设置", systemImage: "gearshape") }
                .tag(SettingsWindowController.Tab.general.rawValue)
            AboutToolsView()
                .tabItem { Label("工具介绍", systemImage: "info.circle") }
                .tag(SettingsWindowController.Tab.about.rawValue)
        }
        .frame(width: 640, height: 520)
    }
}

// MARK: - 基础设置

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var formatsSheet: FormatSheetState?
    @State private var extensionEnabled = false
    @State private var extWatchPath: String? = Shared.extensionWatchRootPath()
    @State private var rootAuthorized = RootAuthorizer.isAuthorized

    var body: some View {
        Form {
            if !rootAuthorized {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("「新建文件」尚未完成根目录授权").font(.callout.weight(.semibold))
                        Text("未授权时，Finder 右键新建文件会失败。建议授权个人主目录（覆盖桌面/文稿/下载及所有子目录）。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("立即授权") { chooseWatchRoot() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(Color.orange.opacity(0.10))
                .cornerRadius(8)
            }

            Section("通用") {
                Toggle("开机自启动", isOn: $settings.launchAtLogin)
                Text("登录后自动在菜单栏显示图标。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("截图") {
                Toggle("启用截图快捷键", isOn: $settings.hotKeyEnabled)
                HStack {
                    Text("全局快捷键")
                    HotKeyRecorder().frame(width: 170, height: 28)
                    Spacer()
                    Text(settings.hotKeyDisplay)
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                .disabled(!settings.hotKeyEnabled)
                Toggle("「完成」时自动保存到默认目录（同时复制到剪贴板）", isOn: $settings.autoSaveOnConfirm)
                Picker("图片格式", selection: $settings.saveAsJPEG) {
                    Text("PNG（无损）").tag(false)
                    Text("JPEG（较小）").tag(true)
                }
                .pickerStyle(.radioGroup)
                HStack {
                    Text("默认保存路径")
                    Text(settings.defaultSavePathDisplay.isEmpty ? "未设置" : settings.defaultSavePathDisplay)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("选择…", action: chooseSaveDirectory)
                }
            }

            Section("新建文件 · Finder 右键菜单") {
                HStack {
                    Image(systemName: extensionEnabled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(extensionEnabled ? Color.green : Color.orange)
                    Text(extensionEnabled ? "Finder 扩展已启用" : "Finder 扩展未启用")
                    Spacer()
                    Button("管理扩展…") {
                        FIFinderSyncController.showExtensionManagementInterface()
                    }
                    Button("刷新") { extensionEnabled = Self.checkExtension() }
                }
                Text("路径：系统设置 → 隐私与安全性 → 扩展 → 添加的扩展 → 勾选 MenuShotFinder。")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Text("已授权根目录")
                    Text(Self.watchRootDisplay())
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("选择根目录…", action: chooseWatchRoot)
                }
                HStack {
                    Text("扩展实际监听")
                    Text(extWatchPath ?? "未上报（启用扩展或重新授权后自动刷新）")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(extWatchPath == nil ? Color.orange : Color.secondary)
                    Spacer()
                    Button("刷新") { extWatchPath = Shared.extensionWatchRootPath() }
                }
                Text("授权后（建议选择个人主目录），其下任意层级文件夹的右键菜单都会出现「新建文件」；授权变更会即时同步给 Finder 扩展。")
                    .font(.caption).foregroundStyle(.secondary)

                FormatListSection(onEdit: { formatsSheet = .edit($0) },
                                  onAdd: { formatsSheet = .new })
            }
        }
        .formStyle(.grouped)
        .onAppear {
            extensionEnabled = Self.checkExtension()
            extWatchPath = Shared.extensionWatchRootPath()
            rootAuthorized = RootAuthorizer.isAuthorized
        }
        .sheet(item: $formatsSheet) { state in
            FormatEditorView(format: state.format) { updated in
                if let updated = updated {
                    if let index = settings.formats.firstIndex(where: { $0.id == updated.id }) {
                        settings.formats[index] = updated
                    } else {
                        settings.formats.append(updated)
                    }
                }
                formatsSheet = nil
            }
            .frame(width: 420, height: 380)
        }
    }

    enum FormatSheetState: Identifiable {
        case new
        case edit(FileFormat)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let f): return f.id.uuidString
            }
        }
        var format: FileFormat? {
            switch self {
            case .new: return nil
            case .edit(let f): return f
            }
        }
    }

    static func checkExtension() -> Bool {
        FIFinderSyncController.isExtensionEnabled
    }

    static func watchRootDisplay() -> String {
        Shared.resolveWatchRoot()?.path ?? "未授权（默认尝试家目录）"
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择截图默认保存目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            settings.defaultSaveBookmark = data
        }
        settings.defaultSavePathDisplay = url.path
    }

    private func chooseWatchRoot() {
        switch RootAuthorizer.authorize(defaultDirectory: nil) {
        case .success(let url):
            Toast.shared.show("已授权并可写入：\(url.path)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                extWatchPath = Shared.extensionWatchRootPath()
                rootAuthorized = RootAuthorizer.isAuthorized
            }
        case .failure(let error):
            guard (error as NSError).code != RootAuthorizer.cancelledCode else { return }
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - 文件格式列表

struct FormatListSection: View {
    @ObservedObject private var settings = AppSettings.shared
    var onEdit: (FileFormat) -> Void
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文件格式列表（\(settings.formats.count)）")
                    .font(.headline)
                Spacer()
                Button {
                    onAdd()
                } label: {
                    Label("添加", systemImage: "plus")
                }
                Button(role: .destructive) {
                    settings.formats = FileFormat.defaults
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
            }
            ForEach($settings.formats) { $format in
                HStack {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(format.name)
                    Text(".\(format.ext)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("编辑") { onEdit(format) }
                        .controlSize(.small)
                    Button {
                        settings.formats.removeAll { $0.id == format.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 新建 / 编辑格式：名称、扩展名、模板内容
struct FormatEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var ext: String
    @State private var template: String
    @State private var id: UUID?
    let onDone: (FileFormat?) -> Void

    init(format: FileFormat?, onDone: @escaping (FileFormat?) -> Void) {
        let f = format ?? FileFormat(name: "", ext: "", template: "")
        _name = State(initialValue: f.name)
        _ext = State(initialValue: f.ext)
        _template = State(initialValue: f.template)
        _id = State(initialValue: format?.id)
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(id == nil ? "添加文件格式" : "编辑文件格式")
                .font(.headline)
            HStack {
                Text("显示名")
                    .frame(width: 60, alignment: .trailing)
                TextField("例如 Markdown", text: $name)
                Text("扩展名")
                    .frame(width: 60, alignment: .trailing)
                TextField("md", text: $ext)
                    .frame(width: 90)
            }
            Text("模板内容（新文件的初始内容）")
                .font(.subheadline).foregroundStyle(.secondary)
            TextEditor(text: $template)
                .font(.system(size: 12).monospaced())
                .border(Color(nsColor: .separatorColor))
            HStack {
                Spacer()
                Button("取消") { onDone(nil) }
                Button("保存") {
                    let cleanExt = ext.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        .lowercased()
                    guard !name.isEmpty, !cleanExt.isEmpty else { return }
                    onDone(FileFormat(id: id ?? UUID(), name: name, ext: cleanExt, template: template))
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || ext.isEmpty)
            }
        }
        .padding()
    }
}

// MARK: - 工具介绍

struct AboutToolsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                featureCard(title: "截图", symbol: "viewfinder",
                            text: "菜单栏或快捷键唤起，支持多显示器（含负坐标屏幕）框选；选区可拖动、8 向调整大小。确认后进入编辑器：矩形 / 椭圆 / 箭头 / 直线 / 画笔 / 文本标注，OCR 文字提取，撤销重做（多步），保存 / 另存为 / 复制，以及钉图悬浮桌面。")
                featureCard(title: "新建文件", symbol: "doc.badge.plus",
                            text: "Finder 右键 →「新建文件」→ 选择格式，即可在当前文件夹创建 Markdown / JSON / YAML / HTML / CSV / Swift / Python 等文件。格式名称、扩展名与模板内容均可在「基础设置」中增删改。支持 Finder 多窗口与深层子目录；只读目录会给出明确失败提示。")
                permissionCard()
                versionCard()
            }
            .padding(20)
        }
    }

    private func featureCard(title: String, symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private func permissionCard() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("所需权限及申请时机", systemImage: "lock.shield")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("屏幕录制").font(.callout.bold())
                    Text("首次点击「截图」时由系统弹窗申请；拒绝后可在系统设置中开启。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("文件访问").font(.callout.bold())
                    Text("新建文件 / 保存路径按需通过系统选择器（打开面板）授权，不做静默扫描。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Finder 扩展").font(.callout.bold())
                    Text("使用「新建文件」前需在 系统设置 → 隐私与安全性 → 扩展 中启用 MenuShotFinder。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("登录项").font(.callout.bold())
                    Text("开启「开机自启」时注册，可随时关闭。应用常驻菜单栏，无后台守护进程。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("打开扩展设置…") {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
                Button("打开屏幕录制设置…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private func versionCard() -> some View {
        HStack {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading) {
                Text("MenuShot").font(.headline)
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0") · 构建于 \(Self.buildStamp()) · 原生 Swift/AppKit · 沙盒运行")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    /// 构建时间水印：用于确认运行的是最新构建
    static func buildStamp() -> String {
        guard let url = Bundle.main.url(forResource: "BuildStamp", withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "未知" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
