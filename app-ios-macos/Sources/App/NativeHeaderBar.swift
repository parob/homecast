import Combine
import SwiftUI
import UIKit
import WebKit

#if os(iOS) && !targetEnvironment(macCatalyst)

/// The top chrome, drawn natively — a **preview**, off by default.
///
/// Asked for on parob/homecast-cloud#120, and then narrowed further: "how does
/// the header work in the normal Apple Home app? we want to mirror that setup".
/// So this is not a custom bar any more. It is a real `UINavigationBar`, hosted
/// by a SwiftUI `NavigationStack` around the web view, configured the way the
/// Home app configures its own:
///
/// | Home app | here |
/// |---|---|
/// | large title = the home's name, chevron opens a menu of homes | `navigationTitle` from the page, `toolbarTitleMenu` of the page's homes |
/// | a status line under the title ("Updating…", "No Response") | `navigationSubtitle` (iOS 26) carrying the relay status in words |
/// | trailing glass buttons | search and ⋯ as ordinary toolbar items — the system draws the glass |
/// | transparent bar, content scrolls under it, title collapses | the web view's own scroll view is registered as the content scroll view |
///
/// The one deliberate deviation is a leading menu button: the drawer carries
/// rooms, settings and automations that the Home app puts in a tab bar this
/// app does not have natively.
///
/// ## The page owns the state, this renders it
///
/// Nothing here reads HomeKit or knows what a home is. `NativeHeaderModel` is a
/// bag of published values the page keeps up to date through `header.setState`
/// (a partial merge — see `merge(_:)`), and every control calls straight back
/// into the page. That is what keeps it cheap to delete if the preview is
/// rejected.
///
/// ## Why the bar must never be shown without the scroll view registered
///
/// UIKit collapses a large title by watching a `UIScrollView`. It finds one on
/// its own only for its own view controllers' content; a `WKWebView` inside a
/// SwiftUI representable is invisible to that search, so `FocusableWebView`
/// registers its scroll view explicitly (`setContentScrollView`). Without that
/// the large title never collapses and the bar reads as a static slab — which
/// was the first thing wrong with the first attempt.
@MainActor
final class NativeHeaderModel: ObservableObject {

    static let shared = NativeHeaderModel()

    struct Home: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// Whether the bar is on screen. Mirrors `AppConfig.nativeHeaderPreview`.
    @Published var enabled: Bool = AppConfig.nativeHeaderPreview

    @Published var title: String = ""
    /// The room, room group or collection being viewed; empty on the home
    /// view. When set and different from `title`, the bar keeps the home name
    /// and the large text is a page heading that scrolls away with the
    /// content instead of handing over.
    @Published var heading: String = ""
    /// The connection state in words — what the Home app puts under its title.
    @Published var subtitle: String = ""
    @Published var homes: [Home] = []
    @Published var currentHomeId: String?
    @Published var showMenu = true
    @Published var showSearch = true
    @Published var showOverflow = true
    /// Whether to draw the large title band. Off in the layout with a
    /// permanent sidebar (landscape phone, iPad), where the page draws its
    /// own heading beside the sidebar and the bar is the compact row alone.
    @Published var largeTitle = true
    /// Whether the page has a status control to open at all.
    @Published var hasStatus = false
    /// The ⋯ menu, as the page published it. Empty means fall back to tapping
    /// the page's own ⋯ (an older page that publishes no menu).
    @Published var menu: [MenuSection] = []
    /// "dark" when the page is drawing light-on-dark, "light" otherwise, nil
    /// until the page has said. The bar follows the page, not the system.
    @Published var appearance: String?
    /// A web overlay (drawer, dialog, popover) is open. The bar hides for it:
    /// it sits above every web layer, and a drawer sliding in under a bar
    /// that stays put is not how a presented sheet behaves.
    @Published var covered = false

    struct MenuItem: Identifiable, Equatable {
        let id: String
        let label: String
        let symbol: String?
        let destructive: Bool
        let disabled: Bool
    }

    struct MenuSection: Identifiable, Equatable {
        let id: String
        let title: String?
        let items: [MenuItem]
    }

    /// What the ☰ button offers: rooms, room groups, collections. Homes moved
    /// to the title menu. Empty means fall back to opening the web drawer.
    @Published var navigation: [NavSection] = []

    struct NavItem: Identifiable, Equatable {
        let id: String
        let label: String
        let symbol: String?
        let selected: Bool
        /// Non-empty makes this a submenu rather than an action.
        let children: [NavItem]
    }

    struct NavSection: Identifiable, Equatable {
        let id: String
        let title: String?
        let items: [NavItem]
    }

    /// Runs JavaScript in the page. Installed by the web view's coordinator;
    /// nil until there is a page, in which case a tap does nothing.
    var runScript: ((String) -> Void)?

    /// Measures the bar for the page. Installed by the hosting controller.
    var reportInsets: ((@escaping (_ barInset: CGFloat, _ statusInset: CGFloat) -> Void) -> Void)?
    /// Tells the page the bar's heights again. Installed by the web view's
    /// coordinator; the hosting controller calls it when a rotation or a
    /// layout change moves them.
    var insetsChanged: ((_ barInset: CGFloat, _ statusInset: CGFloat) -> Void)?


    /// Merge a partial state from the page and redraw.
    ///
    /// **A publish is a partial update, and that is load-bearing.** The title
    /// and the homes come from `AppHeader`, the status text from `StatusBadge`,
    /// and neither knows the other's state. If a publish replaced rather than
    /// merged, a title change would blank the status and a reconnect would
    /// blank the title, several times a second during a pod handoff.
    ///
    /// Applied whether or not the bar is on screen, so that flipping the flag
    /// shows a bar that already knows its title. The first attempt dropped
    /// messages while off and came up blank — that was the second thing wrong.
    func merge(_ payload: [String: Any]) {
        if let value = payload["title"] as? String { title = value }
        if let value = payload["heading"] as? String { heading = value }
        if payload.index(forKey: "subtitle") != nil {
            subtitle = payload["subtitle"] as? String ?? ""
        }
        if let value = payload["showMenu"] as? Bool { showMenu = value }
        if let value = payload["showSearch"] as? Bool { showSearch = value }
        if let value = payload["showOverflow"] as? Bool { showOverflow = value }
        if let value = payload["largeTitle"] as? Bool { largeTitle = value }
        if payload.index(forKey: "statusColor") != nil {
            // Present: a hex string means there is a status to show, JSON null
            // (NSNull here) means the page hid its badge.
            hasStatus = payload["statusColor"] is String
        }
        if let raw = payload["homes"] as? [[String: Any]] {
            homes = raw.compactMap { entry in
                guard let id = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
                return Home(id: id, name: name)
            }
        }
        if payload.index(forKey: "currentHomeId") != nil {
            currentHomeId = payload["currentHomeId"] as? String
        }
        if let raw = payload["menu"] as? [[String: Any]] {
            menu = raw.compactMap { section in
                guard let id = section["id"] as? String,
                      let items = section["items"] as? [[String: Any]] else { return nil }
                return MenuSection(
                    id: id,
                    title: section["title"] as? String,
                    items: items.compactMap { item in
                        guard let itemId = item["id"] as? String, let label = item["label"] as? String else { return nil }
                        return MenuItem(
                            id: itemId,
                            label: label,
                            symbol: item["symbol"] as? String,
                            destructive: item["destructive"] as? Bool ?? false,
                            disabled: item["disabled"] as? Bool ?? false
                        )
                    }
                )
            }
        }
        if let value = payload["appearance"] as? String { appearance = value }
        if let value = payload["covered"] as? Bool { covered = value }
        if let raw = payload["navigation"] as? [[String: Any]] {
            navigation = raw.compactMap { section in
                guard let id = section["id"] as? String, let items = section["items"] as? [[String: Any]] else { return nil }
                return NavSection(id: id, title: section["title"] as? String, items: items.compactMap(Self.navItem))
            }
        }
    }

    private static func navItem(_ raw: [String: Any]) -> NavItem? {
        guard let id = raw["id"] as? String, let label = raw["label"] as? String else { return nil }
        let children = (raw["children"] as? [[String: Any]])?.compactMap(navItem) ?? []
        return NavItem(id: id, label: label, symbol: raw["symbol"] as? String, selected: raw["selected"] as? Bool ?? false, children: children)
    }

    // MARK: - Back into the page

    /// The raw values are the wire format — they cross into JavaScript verbatim
    /// as `window.__homecastNativeHeader.tap('<rawValue>')`.
    enum Control: String {
        case menu, status, search, overflow
    }

    func tap(_ control: Control) {
        runScript?("window.__homecastNativeHeader && window.__homecastNativeHeader.tap('\(control.rawValue)');")
    }

    func navigate(_ id: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [id]),
              let array = String(data: data, encoding: .utf8) else { return }
        runScript?("window.__homecastNativeHeader && window.__homecastNativeHeader.navigate && window.__homecastNativeHeader.navigate(\(array)[0]);")
    }

    func menuAction(_ id: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [id]),
              let array = String(data: data, encoding: .utf8) else { return }
        runScript?("window.__homecastNativeHeader && window.__homecastNativeHeader.menuAction && window.__homecastNativeHeader.menuAction(\(array)[0]);")
    }

    func selectHome(_ id: String) {
        // JSON-encode rather than interpolate: a home id is a UUID today, but
        // the page owns the id space and this must not break on a quote.
        guard let data = try? JSONSerialization.data(withJSONObject: [id]),
              let array = String(data: data, encoding: .utf8) else { return }
        runScript?("window.__homecastNativeHeader && window.__homecastNativeHeader.selectHome && window.__homecastNativeHeader.selectHome(\(array)[0]);")
    }
}

/// Host the web view inside a real `UINavigationController`, the way the Home
/// app hosts its own content.
///
/// Not a SwiftUI `NavigationStack`, and that was learned the hard way: the
/// stack's hosting controller ignores a scroll view registered with
/// `setContentScrollView`, so the large title never expanded and the bar sat
/// compact over a page that was resting at the top. A `UIViewController` we
/// own can answer UIKit's `contentScrollView(for:)` question itself, and then
/// the whole large-title machinery — expand at rest, collapse on scroll, the
/// scroll-edge effect — runs unmodified.
struct NativeHeaderHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let root = WebHostingController(rootView: content)
        let nav = UINavigationController(navigationBarClass: PassthroughNavigationBar.self, toolbarClass: nil)
        nav.viewControllers = [root]
        // Compact bar only; the large title is the controller's own view.
        nav.navigationBar.prefersLargeTitles = false
        root.navigationItem.largeTitleDisplayMode = .never
        root.bind(NativeHeaderModel.shared)
        return nav
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {
        (nav.viewControllers.first as? WebHostingController<Content>)?.rootView = content
    }
}

/// A navigation bar that, when asked, is nothing but its buttons: touches
/// anywhere else fall through to the content beneath. Used in the sidebar
/// layout, where the bar has no title and no background and the content it
/// floats over must stay tappable.
final class PassthroughNavigationBar: UINavigationBar {
    var passesThrough = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard passesThrough, let hit else { return hit }
        // Keep the hit only if it is a control or sits inside one.
        var view: UIView? = hit
        while let current = view, current !== self {
            if current is UIControl { return hit }
            view = current.superview
        }
        return nil
    }
}

/// A scroll view that reports when UIKit changes its insets — which is how the
/// navigation bar tells its content scroll view that the large title grew or
/// shrank.
final class ProxyScrollView: UIScrollView {
    var onAdjustedInsetChange: (() -> Void)?
    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        onAdjustedInsetChange?()
    }
}

/// Layout constants shared with the page's padding contract.
enum WebHostingLayout {
    /// The band under the compact bar that the large title occupies, and the
    /// distance over which it collapses. The page pads its content by the
    /// compact inset plus this.
    static let largeTitleHeight: CGFloat = 52
}

/// The controller in the navigation stack. Renders `NativeHeaderModel` onto
/// its `navigationItem`, draws the large title itself, and drives both from
/// the web view's scrolling.
///
/// ## Why the large title is drawn here and not by UIKit
///
/// UIKit's large title is a morph between two positions of one title control,
/// driven by an interactive drag on the bar's content scroll view. The web
/// view cannot be that scroll view (inset the way UIKit expects, the page's
/// layout viewport starts below the bar and the band under the status bar
/// shows the scroll view's black backdrop instead of the wallpaper), and when
/// UIKit is fed the page's offset through a proxy it has never dragged, the
/// morph degrades: the large title slides up unfaded and unclipped into the
/// menu button, then snaps to the inline title at the threshold (measured,
/// frame by frame). So the bar is kept compact, and the large title is an
/// ordinary view of ours under it: it rides up with the content 1:1, is
/// clipped at the bar's edge and fades, while a custom inline title fades in
/// over the same distance. That is what a finger sees in the Home app, and it
/// is deterministic.
///
/// The proxy scroll view remains — UIKit still needs a content scroll view it
/// believes in to draw the scroll-edge effect under the compact bar once
/// content has moved beneath it.
final class WebHostingController<Content: View>: UIHostingController<Content> {
    private var cancellable: AnyCancellable?
    private var offsetObservation: NSKeyValueObservation?
    private weak var webScrollView: UIScrollView?
    private let proxy = ProxyScrollView()
    /// The compact bar's inset (status bar + bar), as observed while shown.
    private var compactInset: CGFloat = 0
    /// The large text is a page heading (a room, group or collection), not
    /// the home name: the bar's title stays put and nothing crossfades.
    private var headingIsPage = false
    /// Mirrors `NativeHeaderModel.largeTitle`.
    private var largeTitleEnabled = true
    /// The bar is hidden (preview off, or a web overlay is up).
    private var barHidden = false
    /// What the page was last told, so a rotation that changes the bar's
    /// heights tells it again and nothing else does.
    private var lastReportedInsets: (bar: CGFloat, status: CGFloat)?

    /// The band under the compact bar that the large title occupies, and the
    /// distance over which it collapses. The page pads its content by the
    /// compact inset plus this.
    private var largeTitleHeight: CGFloat { WebHostingLayout.largeTitleHeight }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        proxy.frame = view.bounds
        proxy.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        proxy.contentSize = CGSize(width: 1, height: 1_000_000)
        proxy.contentInsetAdjustmentBehavior = .always
        proxy.backgroundColor = .clear
        proxy.isUserInteractionEnabled = false
        proxy.showsVerticalScrollIndicator = false
        proxy.showsHorizontalScrollIndicator = false
        proxy.onAdjustedInsetChange = { [weak self] in self?.mirrorOffset() }
        view.insertSubview(proxy, at: 0)

        navigationItem.titleView = inlineTitle
        buildLargeTitle()
    }

    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        edge == .top && largeTitleEnabled ? proxy : super.contentScrollView(for: edge)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachWebScrollViewIfNeeded()
        layoutLargeTitle()
        reportInsetsIfChanged()
    }

    /// A rotation changes the status bar and the bar's own height; the page
    /// pads by what it was last told, so tell it again.
    private func reportInsetsIfChanged() {
        guard let insetsChanged = NativeHeaderModel.shared.insetsChanged else { return }
        let now = barInsets
        if let last = lastReportedInsets, last.bar == now.bar, last.status == now.status { return }
        lastReportedInsets = now
        insetsChanged(now.bar, now.status)
    }

    /// The web view is created by SwiftUI some time after this controller's
    /// view is; hook it the first time layout finds it.
    private func attachWebScrollViewIfNeeded() {
        guard webScrollView == nil, let scroll = Self.findWebScrollView(in: view) else { return }
        webScrollView = scroll
        // Not the scroll view's delegate: that is WebKit's, and taking it is
        // the kind of thing that breaks a pan without saying so. A target on
        // the pan recogniser and KVO on the offset are enough to know when a
        // drag ends and when the deceleration after it stops.
        scroll.panGestureRecognizer.addTarget(self, action: #selector(webPanChanged(_:)))
        offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            self.mirrorOffset()
            if self.awaitingDecelerationEnd, let scroll = self.webScrollView, !scroll.isDragging, !scroll.isDecelerating {
                self.awaitingDecelerationEnd = false
                self.snapIfNeeded(scroll)
            }
        }
        // Above the web view, which SwiftUI has just added on top of us.
        view.bringSubviewToFront(largeTitleArea)
        mirrorOffset()
    }

    // MARK: - The two titles

    /// The inline title: the name and a small chevron, opening the home menu.
    /// Faded in as the large one fades out.
    private lazy var inlineTitle: UIButton = {
        var config = UIButton.Configuration.plain()
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .headline)
            return attributes
        }
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.contentInsets = .zero
        config.baseForegroundColor = .label
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.alpha = 0
        return button
    }()

    /// The band under the compact bar holding the large title. Not clipped:
    /// the name fades out well before it would reach the bar's edge, so it
    /// dissolves rather than being cut off.
    private let largeTitleArea = UIView()
    /// The whole large title is one button, so the name is the tap target.
    private let largeTitleButton = UIButton(type: .custom)
    private let largeTitleLabel = UILabel()
    /// The status line under the name. A button: tapping it opens the page's
    /// connection popover, which is where that detail lives.
    private let largeSubtitleButton = UIButton(type: .custom)
    private let largeChevron = UIImageView()

    private func buildLargeTitle() {
        largeTitleArea.clipsToBounds = false
        largeTitleArea.backgroundColor = .clear
        view.addSubview(largeTitleArea)

        largeTitleButton.showsMenuAsPrimaryAction = true
        largeTitleButton.accessibilityLabel = "Switch home"
        largeTitleArea.addSubview(largeTitleButton)

        largeTitleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        largeTitleLabel.textColor = .label
        largeTitleLabel.lineBreakMode = .byTruncatingTail
        largeTitleLabel.isUserInteractionEnabled = false
        largeTitleButton.addSubview(largeTitleLabel)

        largeSubtitleButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        largeSubtitleButton.setTitleColor(.secondaryLabel, for: .normal)
        largeSubtitleButton.contentHorizontalAlignment = .leading
        largeSubtitleButton.accessibilityLabel = "Connection status"
        largeSubtitleButton.addAction(UIAction { [weak self] _ in
            _ = self
            NativeHeaderModel.shared.tap(.status)
        }, for: .touchUpInside)
        // A sibling of the title button, above it, so its tap is its own.
        largeTitleArea.addSubview(largeSubtitleButton)

        largeChevron.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        largeChevron.tintColor = .secondaryLabel
        largeChevron.contentMode = .center
        largeChevron.backgroundColor = .tertiarySystemFill
        largeChevron.layer.cornerRadius = 11
        largeChevron.isUserInteractionEnabled = false
        largeTitleButton.addSubview(largeChevron)
    }

    /// Lay the large title out for the current text; `updateTitleTransition`
    /// then moves it with the scroll.
    private func layoutLargeTitle() {
        let inset = compactInset > 0 ? compactInset : view.safeAreaInsets.top
        let height = largeTitleHeight
        largeTitleArea.frame = CGRect(x: 0, y: inset, width: view.bounds.width, height: height)
        largeTitleArea.isHidden = !largeTitleEnabled || barHidden

        let leading = max(view.layoutMargins.left, 16)
        let trailingRoom: CGFloat = 60
        let textWidth = ceil((largeTitleLabel.text ?? "").size(withAttributes: [.font: largeTitleLabel.font as Any]).width)
        let maxTextWidth = max(0, view.bounds.width - leading - trailingRoom)
        let width = min(textWidth, maxTextWidth)
        let hasSubtitle = !(largeSubtitleButton.title(for: .normal) ?? "").isEmpty

        // 34pt bold sits on a 41pt line; with a status line under it the pair
        // is packed a little tighter so it still fits the band.
        let titleHeight: CGFloat = 41
        let titleY: CGFloat = hasSubtitle ? -2 : (height - titleHeight) / 2
        largeTitleLabel.frame = CGRect(x: leading, y: titleY, width: width, height: titleHeight)
        largeSubtitleButton.frame = CGRect(x: leading, y: titleY + titleHeight - 6, width: maxTextWidth, height: 18)
        largeSubtitleButton.isHidden = !hasSubtitle

        let chevronSize: CGFloat = 22
        largeChevron.frame = CGRect(x: leading + width + 8, y: titleY + (titleHeight - chevronSize) / 2 + 2, width: chevronSize, height: chevronSize)
        largeChevron.layer.cornerRadius = chevronSize / 2
        largeTitleButton.frame = CGRect(x: 0, y: 0, width: leading + width + 8 + chevronSize + 8, height: height)

        updateTitleTransition()
    }

    /// Where we are between "large title showing" (0) and "inline title
    /// showing" (1), from the page's offset.
    private var collapseProgress: CGFloat {
        let pageY = max(0, webScrollView?.contentOffset.y ?? 0)
        return min(1, pageY / largeTitleHeight)
    }

    /// Move the large title up with the content and fade it; fade the inline
    /// title in over the last part of that travel.
    ///
    /// The large name is gone by a little over half the travel — before its
    /// top would pass under the bar's controls — so it fades rather than
    /// being clipped, and the inline name takes over from the halfway point.
    private func updateTitleTransition() {
        let pageY = max(0, webScrollView?.contentOffset.y ?? 0)
        largeTitleButton.transform = CGAffineTransform(translationX: 0, y: -pageY)
        largeSubtitleButton.transform = largeTitleButton.transform
        if !largeTitleEnabled {
            // Compact row only: the inline title is the title.
            inlineTitle.alpha = 1
            return
        }
        if headingIsPage {
            // A room, group or collection: the bar already says which home,
            // and the heading is part of the page — it scrolls under the bar
            // like everything else, with no handover to fade.
            largeTitleArea.alpha = 1
            inlineTitle.alpha = 1
            return
        }
        let progress = collapseProgress
        largeTitleArea.alpha = max(0, 1 - progress / 0.55)
        inlineTitle.alpha = max(0, (progress - 0.5) / 0.5)
    }

    // MARK: - Scrolling

    /// Set when a drag ended with momentum; the snap waits for it to stop.
    private var awaitingDecelerationEnd = false

    @objc private func webPanChanged(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended || pan.state == .cancelled, let scroll = webScrollView else { return }
        if scroll.isDecelerating {
            awaitingDecelerationEnd = true
        } else {
            snapIfNeeded(scroll)
        }
    }

    /// Keep the proxy where the page is, in the proxy's own coordinate space,
    /// and the titles where the page's offset says.
    private func mirrorOffset() {
        let inset = proxy.adjustedContentInset.top
        if inset > 0, navigationController?.isNavigationBarHidden == false, compactInset != inset {
            compactInset = inset
            layoutLargeTitle()
            reportInsetsIfChanged()
        }
        let pageY = max(0, webScrollView?.contentOffset.y ?? 0)
        let target = CGPoint(x: 0, y: -inset + pageY)
        if proxy.contentOffset != target {
            proxy.contentOffset = target
        }
        updateTitleTransition()
    }

    /// What UIKit does for its own large titles: never leave one half
    /// collapsed. Below halfway it reopens, above it finishes closing.
    private func snapIfNeeded(_ scroll: UIScrollView) {
        let y = scroll.contentOffset.y
        let band = largeTitleHeight
        guard y > 0, y < band else { return }
        scroll.setContentOffset(CGPoint(x: 0, y: y < band / 2 ? 0 : band), animated: true)
    }

    /// The height the page must keep clear at the top — the compact bar plus
    /// the large title band — and the status bar alone. The page pads its
    /// content by the first and pins its safe-area variable to the second.
    var barInsets: (bar: CGFloat, status: CGFloat) {
        let status = view.window?.safeAreaInsets.top ?? 0
        guard largeTitleEnabled else {
            // Sidebar layout: the bar is two floating buttons over content
            // that lays itself out as it always did. Nothing to clear.
            return (status, status)
        }
        let compact = compactInset > 0 ? compactInset : view.safeAreaInsets.top
        return (compact + largeTitleHeight, status)
    }

    private static func findWebScrollView(in view: UIView) -> UIScrollView? {
        if let web = view as? WKWebView { return web.scrollView }
        for sub in view.subviews {
            if let hit = findWebScrollView(in: sub) { return hit }
        }
        return nil
    }

    // MARK: - Model → bar

    func bind(_ model: NativeHeaderModel) {
        model.reportInsets = { [weak self] completion in
            guard let self else { return }
            // After a layout pass, so a bar that has only just been shown has
            // its height.
            DispatchQueue.main.async {
                self.view.layoutIfNeeded()
                let insets = self.barInsets
                completion(insets.bar, insets.status)
            }
        }
        apply(model)
        cancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in
                // objectWillChange fires before the value lands; apply on the
                // next turn so the item reads the new state.
                DispatchQueue.main.async {
                    guard let self, let model else { return }
                    self.apply(model)
                }
            }
    }

    private func apply(_ model: NativeHeaderModel) {
        let hidden = !model.enabled || model.covered
        barHidden = hidden
        if navigationController?.isNavigationBarHidden != hidden {
            // Animated when an overlay comes and goes, instant for the flag.
            navigationController?.setNavigationBarHidden(hidden, animated: model.enabled)
        }
        // The large title goes with the bar.
        UIView.animate(withDuration: model.enabled ? 0.25 : 0) {
            self.largeTitleArea.isHidden = hidden || !self.largeTitleEnabled
        }

        // Follow the page, not the system. The page draws light-on-dark over a
        // dark wallpaper or in its dark theme whatever the device is set to,
        // and a system-light bar over that is a black title on black. On the
        // controller so our own labels resolve the same way; the page does not
        // read `prefers-color-scheme` (its dark look is a class), so nothing
        // in the web view changes.
        let style: UIUserInterfaceStyle
        switch model.appearance {
        case "dark": style = .dark
        case "light": style = .light
        default: style = .unspecified
        }
        navigationController?.overrideUserInterfaceStyle = style
        let ink: UIColor? = style == .dark ? .white : style == .light ? .black : nil
        navigationController?.navigationBar.tintColor = ink
        inlineTitle.configuration?.baseForegroundColor = ink ?? .label
        largeTitleLabel.textColor = ink ?? .label

        if largeTitleEnabled != model.largeTitle {
            largeTitleEnabled = model.largeTitle
            largeTitleArea.isHidden = !largeTitleEnabled || barHidden
            // In the sidebar layout the sidebar already names and switches
            // homes, so the bar carries no title at all — just its buttons,
            // floating: no scroll-edge band, and taps beside them fall through.
            navigationItem.titleView = largeTitleEnabled ? inlineTitle : UIView()
            setContentScrollView(largeTitleEnabled ? proxy : nil, for: .top)
            if #available(iOS 26.0, *) {
                proxy.topEdgeEffect.isHidden = !largeTitleEnabled
            }
            (navigationController?.navigationBar as? PassthroughNavigationBar)?.passesThrough = !largeTitleEnabled
            lastReportedInsets = nil
        }
        let title = model.title.isEmpty ? "Homecast" : model.title
        let heading = model.heading.trimmingCharacters(in: .whitespaces)
        headingIsPage = !heading.isEmpty && heading != title
        inlineTitle.configuration?.title = title
        largeTitleLabel.text = headingIsPage ? heading : title
        largeSubtitleButton.setTitle(model.subtitle, for: .normal)

        // The title menu is the one selector: this home's rooms and groups,
        // the collections, then the other homes, then the connection.
        // On a page heading the chevron stays with the home name in the bar.
        let menu = Self.buildTitleMenu(model)
        inlineTitle.menu = menu
        largeTitleButton.menu = headingIsPage ? nil : menu
        largeChevron.isHidden = menu == nil || headingIsPage
        inlineTitle.configuration?.image = menu == nil ? nil : UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))

        // No leading button, like the Home app: navigation is the title menu,
        // and the web drawer is reachable from ⋯ for what a menu cannot do.
        navigationItem.leftBarButtonItem = nil

        var trailing: [UIBarButtonItem] = []
        if model.showOverflow {
            if let menu = Self.buildMenu(model) {
                // The page's ⋯ menu, drawn by UIKit. Tapping the item opens the
                // menu directly; an item calls back into the page by id.
                let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
                more.accessibilityLabel = "More"
                trailing.append(more)
            } else {
                trailing.append(item("ellipsis", label: "More") { model.tap(.overflow) })
            }
        }
        if model.showSearch { trailing.append(item("magnifyingglass", label: "Search") { model.tap(.search) }) }
        navigationItem.rightBarButtonItems = trailing

        inlineTitle.sizeToFit()
        layoutLargeTitle()
    }

    private static func buildTitleMenu(_ model: NativeHeaderModel) -> UIMenu? {
        guard !model.homes.isEmpty || !model.navigation.isEmpty else { return nil }
        var children: [UIMenuElement] = []
        // Which home, first and as a row of buttons — one tap, nothing to
        // scroll past. Only when there is more than one to choose from.
        let current = model.currentHomeId
        if model.homes.count > 1 {
            let homes: [UIMenuElement] = model.homes.map { home in
                UIAction(title: home.name, image: UIImage(systemName: home.id == current ? "house.fill" : "house"), state: home.id == current ? .on : .off) { [weak model] _ in
                    model?.selectHome(home.id)
                }
            }
            let row = UIMenu(title: "", options: .displayInline, children: homes)
            if #available(iOS 16.0, *) {
                row.preferredElementSize = .medium
            }
            children.append(row)
        }
        // Where to go in this home: rooms, groups, collections.
        if let navigation = buildNavigationMenu(model) {
            children.append(contentsOf: navigation.children)
        }
        return UIMenu(children: children)
    }

    private static func buildNavigationMenu(_ model: NativeHeaderModel) -> UIMenu? {
        guard !model.navigation.isEmpty else { return nil }
        func element(_ item: NativeHeaderModel.NavItem) -> UIMenuElement {
            let image = item.symbol.flatMap { UIImage(systemName: $0) }
            if !item.children.isEmpty {
                return UIMenu(title: item.label, image: image, children: item.children.map(element))
            }
            return UIAction(title: item.label, image: image, state: item.selected ? .on : .off) { [weak model] _ in
                model?.navigate(item.id)
            }
        }
        let sections: [UIMenu] = model.navigation.map { section in
            UIMenu(title: section.title ?? "", options: .displayInline, children: section.items.map(element))
        }
        return UIMenu(children: sections)
    }

    private static func buildMenu(_ model: NativeHeaderModel) -> UIMenu? {
        guard !model.menu.isEmpty else { return nil }
        let sections: [UIMenu] = model.menu.map { section in
            let actions: [UIAction] = section.items.map { item in
                var attributes: UIMenuElement.Attributes = []
                if item.destructive { attributes.insert(.destructive) }
                if item.disabled { attributes.insert(.disabled) }
                let image = item.symbol.flatMap { UIImage(systemName: $0) }
                return UIAction(title: item.label, image: image, attributes: attributes) { [weak model] _ in
                    model?.menuAction(item.id)
                }
            }
            return UIMenu(title: section.title ?? "", options: .displayInline, children: actions)
        }
        return UIMenu(children: sections)
    }

    private func item(_ symbol: String, label: String, handler: @escaping () -> Void) -> UIBarButtonItem {
        let action = UIAction(image: UIImage(systemName: symbol)) { _ in handler() }
        let item = UIBarButtonItem(primaryAction: action)
        item.accessibilityLabel = label
        return item
    }
}

#endif
