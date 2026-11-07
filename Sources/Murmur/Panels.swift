import AppKit
import SwiftUI

/// Borderless, non-activating floating panel: it never steals focus from the app you're typing in.
final class FloatingPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init<V: View>(size: NSSize, view: V) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }
}

@MainActor
final class Panels {
    private var pill: FloatingPanel?
    private var askPanel: FloatingPanel?
    private weak var model: AppModel?

    static let pillSize = NSSize(width: 420, height: 110)
    static let askSize = NSSize(width: 600, height: 460)

    func attach(_ model: AppModel) {
        self.model = model
        let p = FloatingPanel(size: Self.pillSize, view: PillView(model: model))
        p.ignoresMouseEvents = true
        pill = p
        let a = FloatingPanel(size: Self.askSize, view: AskView(model: model))
        a.allowsKey = true
        askPanel = a
    }

    /// The screen the user is working on (the one with the mouse).
    private var screen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func update() {
        guard let model, let pill, let askPanel else { return }
        let vf = screen.visibleFrame
        if ProcessInfo.processInfo.environment["MURMUR_DEBUG"] != nil {
            NSLog("Murmur panels: phase=\(model.phase) ask=\(model.askVisible) pillVisible=\(pill.isVisible) frame=\(pill.frame) screen=\(vf)")
        }

        let showPill = model.phase != .idle && !(model.askVisible && model.phase == .thinking)
        if showPill {
            if !pill.isVisible {
                pill.setFrameOrigin(NSPoint(x: vf.midX - Self.pillSize.width / 2, y: vf.minY + 8))
                pill.orderFrontRegardless()
            }
        } else if pill.isVisible {
            // Let the SwiftUI exit transition play before hiding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak model] in
                if model?.phase == .idle || (model?.askVisible == true && model?.phase == .thinking) { pill.orderOut(nil) }
            }
        }

        if model.askVisible {
            if !askPanel.isVisible {
                askPanel.setFrameOrigin(NSPoint(x: vf.midX - Self.askSize.width / 2, y: vf.minY + 96))
                askPanel.orderFrontRegardless()
            }
        } else if askPanel.isVisible {
            askPanel.orderOut(nil)
        }
    }
}
