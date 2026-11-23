#if os(iOS)
import SwiftUI
import UIKit

/// Reads this view's native keyboard guide, not global keyboard notifications or focus.
/// Floating keyboards do not consume the bottom edge; a hardware-keyboard accessory
/// alone is not enough to collapse the chat. The parent extends behind the keyboard.
struct DockedKeyboardReader: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> KeyboardProbeView {
        KeyboardProbeView(onChange: onChange)
    }

    func updateUIView(_ view: KeyboardProbeView, context: Context) {
        view.onChange = onChange
    }

    final class KeyboardProbeView: UIView {
        var onChange: (Bool) -> Void
        private var pendingVisible: Bool?
        private var deliveredVisible: Bool?
        private let occupiedArea = LayoutObserverView()

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            keyboardLayoutGuide.followsUndockedKeyboard = false
            occupiedArea.translatesAutoresizingMaskIntoConstraints = false
            addSubview(occupiedArea)
            NSLayoutConstraint.activate([
                occupiedArea.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                occupiedArea.bottomAnchor.constraint(equalTo: bottomAnchor),
                occupiedArea.leadingAnchor.constraint(equalTo: leadingAnchor),
                occupiedArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            occupiedArea.didLayout = { [weak self] in self?.report() }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { setNeedsLayout() }
        }

        private func report() {
            guard window != nil else { return }
            let visible = occupiedArea.bounds.height - safeAreaInsets.bottom > 80
            guard visible != pendingVisible || visible != deliveredVisible else { return }
            pendingVisible = visible
            // Deliver after UIKit finishes layout. Recheck to discard an intermediate
            // keyboard frame if another layout has already superseded it.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.pendingVisible == visible,
                      self.deliveredVisible != visible else { return }
                self.deliveredVisible = visible
                self.onChange(visible)
            }
        }
    }

    private final class LayoutObserverView: UIView {
        var didLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            didLayout?()
        }
    }
}
#endif
