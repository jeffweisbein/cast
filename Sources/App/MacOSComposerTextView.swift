#if os(macOS)
import AppKit

/// Restore the chat insertion point on activation, after AppKit has delivered
/// the click that activated the window. Never compete with another text editor.
final class MacOSComposerTextView: NSTextView {
    var applicationIsActive: () -> Bool = { NSApp.isActive }
    private var focusRequest = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        focusRequest += 1
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activationChanged),
            name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(activationChanged),
            name: NSApplication.didBecomeActiveNotification, object: NSApp)
        requestComposerFocus()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func activationChanged(_ notification: Notification) {
        requestComposerFocus()
    }

    private func requestComposerFocus() {
        focusRequest += 1
        let request = focusRequest
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusRequest == request else { return }
            self.restoreComposerFocus()
        }
    }

    @discardableResult
    func restoreComposerFocus() -> Bool {
        guard applicationIsActive(), let window, window.isKeyWindow,
              !window.isMiniaturized, window.attachedSheet == nil,
              NSApp.modalWindow == nil, !isHiddenOrHasHiddenAncestor,
              isEditable else { return false }
        if window.firstResponder === self { return true }
        if let editor = window.firstResponder as? NSTextView,
           editor.isEditable || editor.selectedRange().length > 0 { return false }
        if let field = window.firstResponder as? NSTextField,
           field.isEditable || field.isSelectable { return false }
        return window.makeFirstResponder(self)
    }
}
#endif
