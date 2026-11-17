#if os(iOS)
import SwiftUI
import UIKit

/// The root SwiftUI value keeps one identity. Replacing a UIHostingController's
/// root every keystroke would reset native input and send-symbol transitions.
final class PendingComposerAccessoryModel: ObservableObject {
    @Published var revision = 0
    var content: PendingComposer?

    func push(_ content: PendingComposer) {
        self.content = content
        revision += 1
    }
}

struct PendingComposerAccessoryRoot: View {
    @ObservedObject var model: PendingComposerAccessoryModel
    var body: some View {
        let _ = model.revision
        if let content = model.content { content.readableColumnWidth() }
    }
}

/// Installs the first-responder owner that vends the composer as an
/// `inputAccessoryView`. Its own view is inert (zero-impact, non-interactive);
/// the visible bar is the separate accessory.
struct PendingComposerAccessory: UIViewControllerRepresentable {
    /// Freshly built by ConversationView.body each render. We don't host this
    /// directly — we copy its fields into the controller's stable model (see
    /// PendingComposerAccessoryModel) so SwiftUI keeps the hosted view's identity.
    let content: PendingComposer

    /// Reports the composer's measured content height (excluding the bottom
    /// safe-area strip) back to ConversationView, so the message list can
    /// reserve that much bottom inset while the keyboard is down — otherwise
    /// the floating accessory covers the last message. Updated as the bar
    /// grows (attachment tray / "+" panel / multi-line text).
    let composerHeight: Binding<CGFloat>

    /// Whether the software keyboard is up — used to fade out the progressive
    /// blur backdrop (it reads as a weird shadow over the keyboard).
    let keyboardVisible: Bool
    /// Actual SwiftUI panel state; height is solely a sizing measurement.
    let panelVisible: Bool

    func makeUIViewController(context: Context) -> PendingComposerAccessoryOwnerController {
        PendingComposerAccessoryOwnerController()
    }

    func updateUIViewController(_ uiViewController: PendingComposerAccessoryOwnerController, context: Context) {
        let sink = composerHeight
        uiViewController.composerHeightSink = { h in
            // Hop off the layout pass before mutating SwiftUI state.
            DispatchQueue.main.async {
                if abs(sink.wrappedValue - h) > 0.5 { sink.wrappedValue = h }
            }
        }
        uiViewController.setKeyboardVisible(keyboardVisible)
        uiViewController.setPanelVisible(panelVisible)
        uiViewController.push(content)
    }

    static func dismantleUIViewController(_ uiViewController: PendingComposerAccessoryOwnerController, coordinator: ()) {
        uiViewController.tearDown()
    }
}

final class PendingComposerAccessoryOwnerController: UIViewController {
    private let model = PendingComposerAccessoryModel()
    private lazy var host = UIHostingController(rootView: PendingComposerAccessoryRoot(model: model))
    private lazy var barContainer = PendingComposerBarContainerView(host: host)
    private var isTearingDown = false
    private var isSuspended = false
    private var observingKeyboardHide = false

    /// Set by the representable; receives the composer's content height
    /// (excluding the bottom safe-area strip) whenever it changes.
    var composerHeightSink: ((CGFloat) -> Void)?

    override var canBecomeFirstResponder: Bool { !isTearingDown && !isSuspended }
    override var inputAccessoryView: UIView? { barContainer }

    override func loadView() {
        let rootView = PendingComposerAccessoryOwnerRootView()
        rootView.backgroundColor = .clear
        rootView.isUserInteractionEnabled = false
        rootView.onMoveToWindow = { [weak self] window in
            guard let self else { return }
            if window != nil {
                self.resumeComposer()
            } else {
                self.suspendComposer()
            }
        }
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        host.view.backgroundColor = .clear
        // Lets the hosting view's intrinsicContentSize track the SwiftUI
        // content so the container can self-size when the "+" panel opens.
        host.sizingOptions = [.intrinsicContentSize]
        barContainer.onContentHeight = { [weak self] h in self?.composerHeightSink?(h) }
    }

    /// Push fresh values into the stable root's model (no rootView swap).
    func push(_ content: PendingComposer) {
        model.push(content)
        barContainer.contentDidChange()
        dockComposerIfPossible()
    }

    func setKeyboardVisible(_ visible: Bool) {
        barContainer.setKeyboardVisible(visible)
    }

    func setPanelVisible(_ visible: Bool) {
        barContainer.setPanelVisible(visible)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Reset in case the view is returning after a presented sheet/cover
        // (camera, photo picker) temporarily took the screen.
        guard !isTearingDown else { return }
        isSuspended = false
        barContainer.setComposerEditingSuspended(false)
        startKeyboardHideObserver()
        // Dock the bar BEFORE the screen is visible so it's already in place
        // when the push transition lands. Becoming first responder in
        // viewDidAppear instead makes the bar visibly slide up after arrival.
        dockComposerIfPossible()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Fallback: if the view wasn't yet in the window during viewWillAppear
        // and couldn't take first responder there, grab it now.
        dockComposerIfPossible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Drop the bar when leaving the screen (navigation pop, or a sheet
        // covering us) so it doesn't linger over whatever comes next.
        suspendComposer()
    }

    /// When the text view resigns (interactive dismiss completes, or the "+"
    /// panel opens), first responder would otherwise fall to nil and the bar
    /// would vanish. Re-grab it so the bar stays docked at the bottom.
    @objc private func keyboardWillHide(_ note: Notification) {
        guard !isTearingDown, !isSuspended, view.window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTearingDown, !self.isSuspended, self.view.window != nil else { return }
            self.dockComposerIfPossible()
        }
    }

    func tearDown() {
        guard !isTearingDown else { return }
        isTearingDown = true
        suspendComposer()
        composerHeightSink = nil
        barContainer.onContentHeight = nil
    }

    private func suspendComposer() {
        // Block hide-notification redocking and queued native focus requests
        // before resigning the real editor living in the accessory window.
        isSuspended = true
        stopKeyboardHideObserver()
        barContainer.setComposerEditingSuspended(true)
        barContainer.endEditing(true)
        resignFirstResponder()
    }

    private func resumeComposer() {
        guard !isTearingDown else { return }
        isSuspended = false
        barContainer.setComposerEditingSuspended(false)
        startKeyboardHideObserver()
        dockComposerIfPossible()
    }

    private func dockComposerIfPossible() {
        guard !isTearingDown,
              !isSuspended,
              view.window != nil,
              !isFirstResponder,
              !barContainer.containsFirstResponder
        else { return }
        becomeFirstResponder()
    }

    private func startKeyboardHideObserver() {
        guard !isTearingDown, !isSuspended, !observingKeyboardHide else { return }
        observingKeyboardHide = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    private func stopKeyboardHideObserver() {
        guard observingKeyboardHide else { return }
        observingKeyboardHide = false
        NotificationCenter.default.removeObserver(
            self,
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }
}

private final class PendingComposerAccessoryOwnerRootView: UIView {
    var onMoveToWindow: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMoveToWindow?(window)
    }
}

private extension UIView {
    func setComposerEditingSuspended(_ suspended: Bool) {
        (self as? PendingComposerUITextView)?.isInteractionSuspended = suspended
        subviews.forEach { $0.setComposerEditingSuspended(suspended) }
    }

    var containsFirstResponder: Bool {
        if isFirstResponder { return true }
        return subviews.contains { $0.containsFirstResponder }
    }
}

/// Self-sizing container for the accessory. Drives its height from the hosted
/// SwiftUI content plus the bottom safe area (the home-indicator strip when
/// docked; zero when riding the keyboard, which iOS reports automatically).
final class PendingComposerBarContainerView: UIView {
    private let host: UIViewController
    private let backdrop = PendingComposerProgressiveBlurBackdropView()
    /// Solid canvas behind the whole bar, shown only while the "+" panel is
    /// open (the progressive blur is hidden then). Pinned to the full container
    /// — including the home-indicator strip — so the panel's opaque backstop
    /// reaches the bottom edge instead of letting messages show through the
    /// strip. The SwiftUI ComposerView can't paint down there itself: its
    /// hosted content sizes above the strip and the accessory's hosting
    /// controller never hands SwiftUI the bottom safe area, so an
    /// `.ignoresSafeArea(.bottom)` background gets no frame in the strip.
    private let canvasBackdrop: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(Theme.Palette.canvas)
        v.isUserInteractionEnabled = false
        v.alpha = 0
        return v
    }()
    private var lastHeight: CGFloat = -1
    private var lastContentHeight: CGFloat = -1
    private var keyboardVisible = false
    private var panelVisible = false
    private var lastBackdropShown = true
    private var lastCanvasShown = false

    /// Reports the content height (excluding the bottom safe-area strip) when
    /// it changes, so the message list can reserve matching bottom inset.
    var onContentHeight: ((CGFloat) -> Void)?

    init(host: UIViewController) {
        self.host = host
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 56))
        // Required for the inputAccessoryView system to honour
        // intrinsicContentSize as the bar's height.
        autoresizingMask = .flexibleHeight

        // Solid canvas backstop, furthest back. Same full-bar pinning as the
        // blur below — see the property comment for why the strip needs a UIKit
        // layer here rather than a SwiftUI background.
        canvasBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvasBackdrop)
        NSLayoutConstraint.activate([
            canvasBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvasBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvasBackdrop.topAnchor.constraint(equalTo: topAnchor),
            canvasBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Progressive blur backdrop pinned to the FULL bar (all four edges,
        // including the home-indicator strip the system reserves below the
        // docked accessory). Painting it here in UIKit — rather than as the
        // SwiftUI ComposerView's `.background` — is what makes it reach the
        // strip: the hosted SwiftUI content sizes to itself and sits above the
        // strip, and the accessory's hosting controller doesn't propagate the
        // bottom safe area to SwiftUI, so a SwiftUI `.ignoresSafeArea(.bottom)`
        // never gets a frame down there. An Auto Layout view pinned to the
        // container edges always covers it. Sits behind the host content,
        // in front of the canvas backstop.
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            // Content sits above the safe-area strip; the strip is added back
            // into intrinsicContentSize so the bar reserves room for it. The
            // backdrop above covers that strip.
            host.view.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func contentDidChange() {
        invalidateIntrinsicContentSize()
    }

    func setKeyboardVisible(_ visible: Bool) {
        guard visible != keyboardVisible else { return }
        keyboardVisible = visible
        refreshBackdrop()
    }

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        refreshBackdrop()
    }

    /// Crossfade the two backstops across three states. Never a hard cut.
    ///   • Docked (keyboard down, panel closed) → blur visible, canvas hidden.
    ///   • Panel open (keyboard down, panel up)  → canvas visible, blur hidden
    ///     (the blur reads as a stray shadow behind the tiles; the solid canvas
    ///     covers the home-indicator strip the panel can't reach itself).
    ///   • Keyboard up → both hidden (either backstop reads as a weird shadow
    ///     over the keyboard).
    private func refreshBackdrop() {
        let blurShown = !keyboardVisible && !panelVisible
        let canvasShown = !keyboardVisible && panelVisible
        if blurShown != lastBackdropShown {
            lastBackdropShown = blurShown
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
                self.backdrop.alpha = blurShown ? 1 : 0
            }
        }
        if canvasShown != lastCanvasShown {
            lastCanvasShown = canvasShown
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
                self.canvasBackdrop.alpha = canvasShown ? 1 : 0
            }
        }
    }

    /// Composer content height, excluding the bottom safe-area strip.
    private func contentHeight() -> CGFloat {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let fitted = host.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return fitted.height
    }

    private func measuredHeight() -> CGFloat {
        contentHeight() + safeAreaInsets.bottom
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight())
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Catch height changes that come from the hosted content itself
        // (e.g. the "+" panel toggling) rather than from setContent. The
        // guard prevents an invalidate→layout→invalidate loop.
        let content = contentHeight()
        let h = content + safeAreaInsets.bottom
        if abs(h - lastHeight) > 0.5 {
            lastHeight = h
            invalidateIntrinsicContentSize()
        }
        if abs(content - lastContentHeight) > 0.5 {
            lastContentHeight = content
            onContentHeight?(content)
        }
    }
}
#endif
