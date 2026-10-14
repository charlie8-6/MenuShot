import AppKit
import SwiftUI

/// 快捷键录制控件：点击后按下组合键完成录制（需含修饰键）。
final class HotKeyRecorderView: NSView {

    private var recording = false {
        didSet { updateAppearance() }
    }
    private let label = NSTextField(labelWithString: "")

    var onChange: ((UInt32, UInt32) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 6
    }

    private func updateAppearance() {
        if recording {
            label.stringValue = "请按下组合键（Esc 取消）"
            label.textColor = .white
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        } else {
            label.stringValue = "点击录制快捷键"
            label.textColor = .labelColor
            layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.3).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        recording.toggle()
        if recording {
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return }
        // 修饰键本身不作为主键
        let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if event.keyCode == 53 { // Esc
            recording = false
            return
        }
        let mods = HotKeyCenter.carbonModifiers(from: event.modifierFlags)
        guard mods != 0, !modifierOnlyKeyCodes.contains(event.keyCode) else {
            label.stringValue = "需包含 ⌘/⌥/⌃/⇧"
            return
        }
        onChange?(UInt32(event.keyCode), mods)
        recording = false
        AppSettings.shared.hotKeyCode = UInt32(event.keyCode)
        AppSettings.shared.hotKeyCarbonMods = mods
    }

    override var isFlipped: Bool { true }
}

struct HotKeyRecorder: NSViewRepresentable {
    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        return view
    }
    func updateNSView(_ nsView: HotKeyRecorderView, context: Context) {}
}
