import SwiftUI
import ImageIO
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A presentation-only projection of an AAUV draft file. The host retains its
/// staged file and owns attachment preparation, removal and persistence.
struct PendingComposerFile: Identifiable {
    let id: UUID
    let name: String
    var url: URL? = nil
}

/// Port of PendingBot's frozen ComposerView. All effects leave through the
/// host callbacks; no account, server, upload or storage dependency lives here.
struct PendingComposer: View {
    @Binding var input: String
    var files: [PendingComposerFile]
    var canSend: Bool
    var isStreaming: Bool = false
    var attachmentsDisabled: Bool = false
    var isPreparingAttachments: Bool = false
    var showsRetry: Bool = false
    var canRetry: Bool = false
    var stopLabel: String = "停止生成"
    var onFiles: () -> Void
    var onPhotos: () -> Void
    var onCamera: (() -> Void)? = nil
    var onRemoveFile: (UUID) -> Void
    var onSend: () -> Void
    var onStop: () -> Void = {}
    var onRetry: () -> Void = {}
    var privacyCovered = false
    var hostEnabled = true
    var onPanelVisibilityChange: (Bool) -> Void = { _ in }
    @Environment(\.isEnabled) private var environmentEnabled

    @State private var showActions = false
    // Keep a plain Bool: the native text view owns actual first-responder
    // state. SwiftUI FocusState across the accessory host drops per keystroke.
    @State private var isFocused = false

    private var interactionEnabled: Bool { hostEnabled && environmentEnabled && !privacyCovered }

    /// Values needed across the UIKit hosting boundary are passed explicitly.
    func configuredForDock(enabled: Bool, onPanelVisibilityChange: @escaping (Bool) -> Void = { _ in }) -> Self {
        var copy = self
        copy.hostEnabled = enabled
        copy.onPanelVisibilityChange = onPanelVisibilityChange
        return copy
    }

    var body: some View {
        VStack(spacing: 0) {
            if isPreparingAttachments {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在准备附件…")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.top, 8)
                .background(Theme.Palette.canvas)
            }
            if !files.isEmpty { pendingTray }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    PendingComposerFeedback.tap()
                    // Focus changes use UIKit's keyboard curve, separately
                    // from the short animation of the attachment panel.
                    if showActions {
                        withAnimation(.easeInOut(duration: 0.22)) { showActions = false }
                        isFocused = true
                    } else {
                        isFocused = false
                        withAnimation(.easeInOut(duration: 0.22)) { showActions = true }
                    }
                } label: {
                    Image(systemName: showActions ? "xmark" : "plus")
                        .font(Theme.Fonts.glyph(size: 18, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .frame(width: 38, height: 38)
                        .pendingComposerSurface(shape: Circle())
                }
                .buttonStyle(.plain)
                .disabled(attachmentsDisabled)
                .accessibilityLabel(showActions ? "关闭附件面板" : "添加附件")

                HStack(alignment: .bottom, spacing: 6) {
                    PendingComposerTextField(
                        text: $input,
                        placeholder: "发消息…",
                        isFocused: $isFocused,
                        onHardwareReturn: { if interactionEnabled && canSend && !isStreaming { onSend() } }
                    )
                    .onChange(of: isFocused) { _, focused in
                        if focused {
                            withAnimation(.easeInOut(duration: 0.22)) { showActions = false }
                        }
                    }
                    .padding(.leading, 14)
                    .padding(.vertical, 4)

                    // AAUV has a persisted unanswered-prompt retry flow. Keep
                    // it in the same capsule and leave its policy to the host.
                    if showsRetry && !isStreaming {
                        Button(action: onRetry) {
                            Image(systemName: "arrow.clockwise")
                                .font(Theme.Fonts.glyph(size: 15, weight: .medium))
                                .foregroundStyle(Theme.Palette.inkMuted)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canRetry)
                        .accessibilityLabel("获取回复")
                        .padding(.bottom, 4)
                    }

                    Button(action: { isStreaming ? onStop() : onSend() }) {
                        Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                            .font(Theme.Fonts.glyph(size: isStreaming ? 12 : 15, weight: .bold))
                            .contentTransition(.symbolEffect(.replace.upUp))
                            .foregroundStyle(
                                isStreaming || canSend ? .white : Theme.Palette.inkMuted.opacity(0.5)
                            )
                            .frame(width: 30, height: 30)
                            .background(
                                Circle().fill(
                                    isStreaming || canSend ? Theme.Palette.accent : Theme.Palette.surfaceMuted
                                )
                            )
                            .animation(.easeInOut(duration: 0.18), value: canSend)
                            .animation(.easeInOut(duration: 0.18), value: isStreaming)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isStreaming && !canSend)
                    .accessibilityLabel(isStreaming ? stopLabel : "发送")
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
                }
                .pendingComposerSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 12)

            if showActions {
                PendingComposerActionPanel(
                    onPickPhoto: onPhotos,
                    onPickCamera: onCamera,
                    onPickFile: onFiles,
                    onDismiss: { showActions = false }
                )
                .disabled(attachmentsDisabled)
                .fixedSize(horizontal: false, vertical: true)
                // Preserve the original panel's breathing room on wide layouts,
                // while allowing the adaptive tile grid to grow on narrow ones.
                .frame(minHeight: 240, alignment: .top)
                .background(Theme.Palette.canvas)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .blur(radius: privacyCovered ? 24 : 0)
        .disabled(!interactionEnabled)
        .allowsHitTesting(interactionEnabled)
        .accessibilityHidden(privacyCovered)
        .onChange(of: interactionEnabled) { _, enabled in
            if !enabled {
                isFocused = false
                showActions = false
            }
        }
        .onChange(of: showActions) { _, visible in onPanelVisibilityChange(visible) }
        .onAppear { onPanelVisibilityChange(showActions) }
        .onDisappear { onPanelVisibilityChange(false) }
    }

    private var pendingTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.Palette.surfaceMuted)
                            .frame(width: 64, height: 64)
                            .overlay(PendingComposerFileThumbnail(file: file))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                            )
                        Button {
                            onRemoveFile(file.id)
                            PendingComposerFeedback.tap()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(Theme.Fonts.body)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除 \(file.name)")
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 8)
        }
        .background(Theme.Palette.canvas)
    }
}

/// Local thumbnails replace the server/upload-backed pending-attachment cell.
/// ImageIO bounds decoded memory; AAUV's staged UUID filenames need the
/// original display name to recognize image extensions.
private struct PendingComposerFileThumbnail: View {
    let file: PendingComposerFile
    @State private var thumbnail: Thumbnail?

    private struct Thumbnail: @unchecked Sendable { let image: CGImage }

    private var isImage: Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tif", "tiff", "bmp"]
            .contains((file.name as NSString).pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if isImage {
                if let thumbnail {
                    Image(decorative: thumbnail.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(Theme.Fonts.glyph(size: 22))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            } else {
                VStack(spacing: 3) {
                    Image(systemName: "doc.fill")
                        .font(Theme.Fonts.glyph(size: 20))
                        .foregroundStyle(Theme.Palette.accent)
                    Text(file.name)
                        .font(Theme.Fonts.system(size: 9))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 4)
            }
        }
        .accessibilityLabel(file.name)
        .task(id: file.url) {
            thumbnail = nil
            guard isImage, let url = file.url else { return }
            let processing = Task.detached(priority: .userInitiated) { Self.readThumbnail(url) }
            let result = await withTaskCancellationHandler {
                await processing.value
            } onCancel: { processing.cancel() }
            guard !Task.isCancelled else { return }
            thumbnail = result
        }
    }

    nonisolated private static func readThumbnail(_ url: URL) -> Thumbnail? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 192,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), !Task.isCancelled else { return nil }
        return Thumbnail(image: image)
    }
}

private enum PendingComposerFeedback {
    #if os(iOS)
    private static let selection = UISelectionFeedbackGenerator()
    @MainActor static func tap() { selection.selectionChanged() }
    #else
    @MainActor static func tap() {}
    #endif
}

// ── Floating surface backing ───────────────────────────────────────────────

/// Pure-white pill / circle with a barely-there drop shadow, used as the
/// background for both the "+" button and the input capsule. On iOS 26 we
/// upgrade to Liquid Glass via `.glassEffect`, which adds depth-aware
/// refraction on top of the same white tint and softer shadow.
private extension View {
    @ViewBuilder
    func pendingComposerSurface<S: InsettableShape>(shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .background(shape.fill(Theme.Palette.surface))
                .glassEffect(.regular, in: shape)
                .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 1)
        } else {
            self
                .background(shape.fill(Theme.Palette.surface))
                .overlay(shape.strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
        }
    }
}

// ── Progressive blur backdrop ──────────────────────────────────────────────

/// Soft top-to-bottom blur sitting behind the floating composer. Messages
/// scrolling underneath fade from fully visible at the top edge of the
/// inset region to fully blurred down past the home indicator. A single
/// `UIVisualEffectView` with a `CAGradientLayer` mask: the gradient runs
/// from clear → opaque downwards, so the blur layer is invisible at the
/// top and fully revealed at the bottom.
///
/// Earlier draft stacked 4 layered blurs of increasing strength to fake a
/// variable-radius Gaussian, but the visual outcome wasn't worth the
/// complexity — the single masked blur reads as a clean reveal here.
///
/// Used directly (as a UIView) by PendingComposerBarContainerView, which pins it to
/// the full accessory bounds so it covers the home-indicator strip — see
/// ChatComposerAccessory.swift.
#if os(iOS)
final class PendingComposerProgressiveBlurBackdropView: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(blur)
        blur.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Multi-stop gradient gives a softer ramp than a 0→1 linear; the
        // 0.0/0.35/0.7/1.0 stops with eased alpha hide the seam where the
        // mask first reveals the blur layer.
        gradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.15).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.withAlphaComponent(1).cgColor,
        ]
        gradient.locations = [0.0, 0.35, 0.7, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        blur.layer.mask = gradient
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Disable implicit CALayer animation — the gradient mask should
        // snap to new bounds during keyboard/inset frame changes, not
        // animate independently from UIKit's transition.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = blur.bounds
        CATransaction.commit()
    }
}

// ── Composer text input ────────────────────────────────────────────────────

/// UITextView-backed input that grows up to 6 lines, distinguishes
/// hardware-Return-as-send from Shift+Return-as-newline, and
/// preserves newlines on paste. SwiftUI's `TextField(axis: .vertical)`
/// can do none of those: it can't see the modifier flags on a
/// keypress, and its `onChange` fires for every newline regardless of
/// source (paste vs typed), which made any paste containing a
/// linebreak fire send immediately.
///
/// Behavior summary:
/// - Soft keyboard Return → newline (no auto-send).
/// - Hardware Return (no modifiers) → calls `onHardwareReturn`, doesn't
///   insert a newline. That's the Mac Catalyst / iPad-keyboard "send".
/// - Hardware Shift+Return → default UITextView behaviour: newline.
/// - Paste → newlines preserved verbatim; no send.
struct PendingComposerTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    let onHardwareReturn: () -> Void

    /// Cap on auto-grown height — matches the old `lineLimit(1...6)`.
    private static let maxLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PendingComposerUITextView {
        let tv = PendingComposerUITextView()
        tv.delegate = context.coordinator
        context.coordinator.isEnabled = context.environment.isEnabled
        tv.environmentAllowsEditing = context.environment.isEnabled
        tv.font = .systemFont(ofSize: Theme.Fonts.scaled(16))
        tv.textColor = UIColor(Theme.Palette.ink)
        tv.tintColor = UIColor(Theme.Palette.accent)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false   // lets intrinsicContentSize drive height
        tv.returnKeyType = .default  // soft-keyboard Return inserts \n
        tv.onHardwareReturn = { [weak coordinator = context.coordinator, weak tv] in
            // Recheck current native permissions after the run-loop hop. A
            // privacy/disabled/teardown change must cancel an already queued send.
            DispatchQueue.main.async { [weak coordinator, weak tv] in
                guard let coordinator, coordinator.isEnabled, tv?.isEditable == true else { return }
                coordinator.parent.onHardwareReturn()
            }
        }
        // Placeholder is rendered as a child label so its color tracks
        // the surrounding palette (UITextView has no built-in placeholder).
        let ph = UILabel()
        ph.text = placeholder
        ph.font = tv.font
        ph.textColor = UIColor(Theme.Palette.inkMuted).withAlphaComponent(0.6)
        ph.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.leadingAnchor.constraint(equalTo: tv.leadingAnchor),
            ph.topAnchor.constraint(equalTo: tv.topAnchor, constant: 6),
        ])
        context.coordinator.placeholder = ph
        context.coordinator.refreshPlaceholder(tv)
        return tv
    }

    func updateUIView(_ uiView: PendingComposerUITextView, context: Context) {
        context.coordinator.parent = self
        let enabled = context.environment.isEnabled
        context.coordinator.isEnabled = enabled
        uiView.environmentAllowsEditing = enabled
        let wantsFocus = enabled && !uiView.isInteractionSuspended && isFocused
        context.coordinator.requestedFocus = wantsFocus
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
            context.coordinator.refreshPlaceholder(uiView)
            context.coordinator.invalidateHeight(uiView)
        }
        // Sync focus state both ways: SwiftUI → UIKit.
        if wantsFocus, !uiView.isFirstResponder {
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak uiView] in
                guard coordinator?.requestedFocus == true, let uiView, !uiView.isFirstResponder else { return }
                uiView.becomeFirstResponder()
            }
        } else if !wantsFocus, uiView.isFirstResponder {
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak uiView] in
                guard coordinator?.requestedFocus == false, let uiView, uiView.isFirstResponder else { return }
                uiView.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: PendingComposerUITextView, coordinator: Coordinator) {
        coordinator.isEnabled = false
        coordinator.requestedFocus = false
        uiView.onHardwareReturn = nil
        uiView.delegate = nil
        uiView.isInteractionSuspended = true
        uiView.resignFirstResponder()
    }

    @MainActor
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PendingComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = (uiView.font?.lineHeight ?? 20)
        let maxHeight = lineHeight * Self.maxLines + uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let height = min(fitted.height, maxHeight)
        // Toggle internal scrolling once the text outgrows the cap so
        // the user can still scroll within the bubble.
        if uiView.isScrollEnabled != (fitted.height > maxHeight) {
            uiView.isScrollEnabled = fitted.height > maxHeight
        }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PendingComposerTextField
        weak var placeholder: UILabel?
        var requestedFocus = false
        var isEnabled = true

        init(_ parent: PendingComposerTextField) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard isEnabled, textView.isEditable else { return }
            parent.text = textView.text ?? ""
            refreshPlaceholder(textView)
            invalidateHeight(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard isEnabled, textView.isEditable else { textView.resignFirstResponder(); return }
            requestedFocus = true
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            requestedFocus = false
            if parent.isFocused { parent.isFocused = false }
        }

        func refreshPlaceholder(_ textView: UITextView) {
            placeholder?.isHidden = !(textView.text?.isEmpty ?? true)
        }

        func invalidateHeight(_ textView: UITextView) {
            textView.invalidateIntrinsicContentSize()
        }
    }
}

/// UITextView subclass that intercepts plain hardware Return so the
/// host can treat it as "send". Shift+Return falls through to the
/// default behaviour (newline). Soft-keyboard Return arrives via the
/// normal text input pipeline (not `pressesBegan`) and is therefore
/// unaffected — it still inserts a newline.
final class PendingComposerUITextView: UITextView {
    var onHardwareReturn: (() -> Void)?
    var environmentAllowsEditing = true { didSet { refreshEditingPermissions() } }
    var isInteractionSuspended = false { didSet { refreshEditingPermissions() } }

    override var canBecomeFirstResponder: Bool {
        environmentAllowsEditing && !isInteractionSuspended && super.canBecomeFirstResponder
    }

    private func refreshEditingPermissions() {
        let enabled = environmentAllowsEditing && !isInteractionSuspended
        isEditable = enabled
        isSelectable = enabled
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isEditable, !isInteractionSuspended else { return }
        if let key = presses.first?.key,
           key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter,
           !key.modifierFlags.contains(.shift),
           !key.modifierFlags.contains(.alternate),
           // markedTextRange != nil means an IME (e.g. 拼音) is mid-
           // composition — Return there commits the candidate, not a
           // send. Fall through so UITextView handles the commit.
           markedTextRange == nil {
            onHardwareReturn?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
#elseif os(macOS)

// ── Composer text input (macOS twin) ───────────────────────────────────────

/// NSTextView-backed input mirroring the iOS `PendingComposerTextField` UITextView
/// twin. A plain SwiftUI `TextField` can't be used here: its bound `String`
/// stays empty while an IME (拼音 etc.) is mid-composition, so a
/// `text.isEmpty` placeholder never hides and ends up painted on top of the
/// candidate letters the user is typing. NSTextView exposes `hasMarkedText()`,
/// which lets the placeholder disappear the moment composition starts.
///
/// Behavior summary (kept identical to the previous SwiftUI version):
/// - Plain hardware Return → calls `onHardwareReturn` (send), no newline.
/// - Shift+Return / Option+Return → inserts a newline.
/// - Grows 1–6 lines, then scrolls internally.
/// - `isFocused` ⇄ first-responder kept in sync both directions.
/// - Placeholder visible iff the field is empty AND not composing (marked text).
struct PendingComposerTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    let onHardwareReturn: () -> Void

    /// Cap on auto-grown height — matches the old `lineLimit(1...6)`.
    private static let maxLines: CGFloat = 6

    private var font: NSFont { .systemFont(ofSize: Theme.Fonts.scaled(16)) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .allowed

        let tv = PendingComposerNSTextView()
        tv.delegate = context.coordinator
        tv.font = font
        tv.textColor = NSColor(Theme.Palette.ink)
        tv.insertionPointColor = NSColor(Theme.Palette.accent)
        tv.drawsBackground = false
        tv.isRichText = false
        context.coordinator.isEnabled = context.environment.isEnabled
        tv.isEditable = context.environment.isEnabled
        tv.isSelectable = context.environment.isEnabled
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 0, height: 6)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Marked-text (IME candidate) changes don't fire the text-did-change
        // delegate, so hook the composition entry points directly to keep the
        // placeholder visibility honest while the user is still typing pinyin.
        tv.onMarkedTextChange = { [weak coordinator = context.coordinator, weak tv] in
            guard let coordinator, let tv else { return }
            coordinator.refreshPlaceholder(tv)
        }
        // Focus tracking hangs off the responder chain, NOT the
        // textDidBegin/EndEditing delegate pair: AppKit only posts
        // textDidBeginEditing on the first actual text change (unlike iOS,
        // where focus alone begins editing). With the delegate pair, a click
        // left `isFocused` false, and the next host re-render (a streaming
        // reply re-renders the conversation constantly) hit updateNSView's
        // "binding says unfocused but we're first responder" branch and stole
        // focus back — the "click, then focus drops unless you type" bug.
        tv.onFocusChange = { [weak coordinator = context.coordinator] focused in
            guard let coordinator else { return }
            // Keep the async make/resign guards' snapshot in sync too, so a
            // stale queued resign can't fire against the new reality.
            let allowedFocus = focused && coordinator.isEnabled
            coordinator.requestedFocus = allowedFocus
            if coordinator.parent.isFocused != allowedFocus {
                coordinator.parent.isFocused = allowedFocus
            }
        }
        scrollView.documentView = tv

        // Placeholder is drawn by the text view itself (see PendingComposerNSTextView
        // .draw) — NOT an NSTextField subview of the scroll view. Two reasons,
        // both hard-learned: Auto Layout constraints on a direct subview of
        // NSScrollView are never applied (NSScrollView's layout pass is tile(),
        // which skips the constraint engine → the label stays at its initial
        // frame, top-left + truncated), and an NSTextField overlay swallows
        // mouse-downs over exactly the strip where the placeholder text shows,
        // so click-to-focus dies there. Drawing at textContainerOrigin with the
        // same font is pixel-aligned with real text by construction and leaves
        // hit-testing entirely to the text view.
        tv.placeholderString = placeholder
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let enabled = context.environment.isEnabled
        context.coordinator.isEnabled = enabled
        let wantsFocus = enabled && isFocused
        context.coordinator.requestedFocus = wantsFocus
        guard let tv = nsView.documentView as? PendingComposerNSTextView else { return }
        tv.isEditable = enabled
        tv.isSelectable = enabled
        if tv.placeholderString != placeholder {
            tv.placeholderString = placeholder
            tv.needsDisplay = true
        }
        // Don't stomp an in-flight IME composition; only push external text
        // changes (send-clear, @-mention insertion) when not composing.
        if !tv.hasMarkedText(), tv.string != text {
            tv.string = text
            context.coordinator.refreshPlaceholder(tv)
        }
        let isFirst = (tv.window?.firstResponder === tv)
        if wantsFocus, !isFirst {
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak tv] in
                guard coordinator?.requestedFocus == true, let tv,
                      let window = tv.window, window.firstResponder !== tv else { return }
                window.makeFirstResponder(tv)
            }
        } else if !wantsFocus, isFirst {
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak tv] in
                guard coordinator?.requestedFocus == false, let tv,
                      let window = tv.window, window.firstResponder === tv else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.isEnabled = false
        coordinator.requestedFocus = false
        guard let tv = nsView.documentView as? PendingComposerNSTextView else { return }
        tv.onFocusChange = nil
        tv.onMarkedTextChange = nil
        tv.delegate = nil
        tv.isEditable = false
        tv.isSelectable = false
        if tv.window?.firstResponder === tv { tv.window?.makeFirstResponder(nil) }
    }

    @MainActor
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let inset = (nsView.documentView as? NSTextView)?.textContainerInset ?? NSSize(width: 0, height: 6)
        let verticalInset = inset.height * 2
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let oneLine = ("M" as NSString).size(withAttributes: attrs).height
        let maxHeight = oneLine * Self.maxLines + verticalInset
        let measured = (nsView.documentView as? NSTextView)?.string ?? text
        let bounding = (measured.isEmpty ? " " : measured as String).boundingRect(
            with: NSSize(width: max(0, width - inset.width * 2), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        let content = ceil(bounding.height) + verticalInset
        let height = min(max(content, oneLine + verticalInset), maxHeight)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PendingComposerTextField
        var requestedFocus = false
        var isEnabled = true

        init(_ parent: PendingComposerTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard isEnabled, let tv = notification.object as? NSTextView, tv.isEditable else { return }
            parent.text = tv.string
            refreshPlaceholder(tv)
        }

        // NOTE: no textDidBeginEditing/textDidEndEditing here — focus sync
        // rides PendingComposerNSTextView's become/resignFirstResponder overrides
        // (see onFocusChange in makeNSView). The editing notifications fire
        // too late on AppKit (first keystroke, not focus) to be a focus signal.

        /// Intercept the plain Return so it sends instead of inserting a
        /// newline. Shift/Option+Return fall through to the default newline.
        /// While an IME is composing (`hasMarkedText`), Return is consumed by
        /// the input method to commit the candidate and never reaches here, but
        /// the guard makes that explicit and fail-safe.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard isEnabled, textView.isEditable else { return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                let wantsNewline = flags.contains(.shift) || flags.contains(.option)
                if !wantsNewline, !textView.hasMarkedText() {
                    parent.onHardwareReturn()
                    return true
                }
            }
            return false
        }

        func refreshPlaceholder(_ textView: NSTextView) {
            // Visibility is decided inside PendingComposerNSTextView.draw (empty &&
            // not composing); this just schedules a repaint on state changes.
            textView.needsDisplay = true
        }
    }
}

/// NSTextView subclass that surfaces IME composition changes. `setMarkedText`
/// / `unmarkText` are the entry/exit points for marked (candidate) text and
/// don't trigger `textDidChange`, so we notify from them to keep the
/// placeholder hidden the instant composition starts and restored when it
/// clears.
final class PendingComposerNSTextView: NSTextView {
    var onMarkedTextChange: (() -> Void)?
    /// Fired from become/resignFirstResponder — the only reliable focus signal
    /// on AppKit (textDidBeginEditing waits for the first keystroke).
    var onFocusChange: ((Bool) -> Void)?
    /// Placeholder drawn in `draw(_:)` when empty and not composing. Drawn (not
    /// an overlay view) so it can't intercept clicks and is positioned at the
    /// exact text origin — see the comment at the construction site.
    var placeholderString: String = ""

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !placeholderString.isEmpty, string.isEmpty, !hasMarkedText() else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: Theme.Fonts.scaled(16)),
            .foregroundColor: NSColor(Theme.Palette.inkMuted).withAlphaComponent(0.6),
        ]
        let origin = NSPoint(
            x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerOrigin.y
        )
        NSAttributedString(string: placeholderString, attributes: attrs).draw(at: origin)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChange?()
    }
}
#endif

private struct PendingComposerActionPanel: View {
    var onPickPhoto: () -> Void
    var onPickCamera: (() -> Void)?
    var onPickFile: () -> Void
    var onDismiss: () -> Void
    private static let tileWidth: CGFloat = 64
    private static let tileSpacing: CGFloat = 18

    // All pickers (photo / camera / file) are presented by the host from the
    // main view tree via bindings, not from here — this panel lives inside the
    // composer's inputAccessoryView, and presenting a sheet / fullScreenCover
    // from a hosting controller embedded in the accessory is unreliable.

    /// 一个格子的宽度 / 格子之间的间距。网格按这两个数算一行能放几个。

    var body: some View {
        VStack(spacing: 0) {
            // 自适应网格,不是横排 —— 满配 6 个格子要 6×64 + 5×18 = 474 点,
            // 而 iPhone 可用宽度只有 393 − 2×16 = 361 点。原来那个 HStack
            // **没有换行这个能力**,超出去的部分直接溢出屏幕两侧(作者 Todo #22
            // 的截图里左右各露半个格子,就是这个)。
            //
            // `.adaptive(minimum:maximum:)` 两头都钉死在 64:一行放得下几个由
            // 可用宽度决定,放不下就自己换行,而格子本身不会被拉宽变形。
            // 用原生网格而不是手写流式布局 —— 本仓库的规矩是能不自绘就不自绘。
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.tileWidth, maximum: Self.tileWidth),
                                   spacing: Self.tileSpacing,
                                   alignment: .top)],
                alignment: .leading,
                spacing: Self.tileSpacing
            ) {
                Button {
                    PendingComposerFeedback.tap()
                    onPickPhoto()
                    onDismiss()
                } label: {
                    actionTileLabel(icon: "photo.on.rectangle.angled", label: "图片")
                }
                .buttonStyle(.plain)

                #if os(iOS)
                // Camera capture is iOS-only — Macs have no camera path
                // (UIImagePickerController is unavailable on macOS).
                if onPickCamera != nil {
                Button {
                    PendingComposerFeedback.tap()
                    onPickCamera?()
                    onDismiss()
                } label: {
                    actionTileLabel(icon: "camera", label: "拍照")
                }
                .buttonStyle(.plain)
                }
                #endif

                Button {
                    PendingComposerFeedback.tap()
                    onPickFile()
                    onDismiss()
                } label: {
                    actionTileLabel(icon: "doc", label: "文件")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 18)
            .padding(.bottom, 18)

            Spacer(minLength: 0)
        }
        .background(Theme.Palette.canvas)
    }

    private func actionTileLabel(icon: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(Theme.Fonts.glyph(size: 22, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                )
            Text(label)
                .font(Theme.Fonts.rounded(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.inkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 64)
    }
}

#if os(iOS)
/// Thin UIImagePickerController wrapper for the camera. PhotosPicker is
/// already used for library selection; UIKit's picker is the cleanest
/// way to get a one-shot camera capture without dragging in AVFoundation.
/// iOS-only — `UIImagePickerController` doesn't exist on macOS and Macs
/// have no camera capture path here.
struct PendingComposerCameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            onPick(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPick(nil)
        }
    }
}
#endif
