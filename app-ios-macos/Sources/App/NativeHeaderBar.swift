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
    /// The connection state in words — what the Home app puts under its title.
    @Published var subtitle: String = ""
    @Published var homes: [Home] = []
    @Published var currentHomeId: String?
    @Published var showMenu = true
    @Published var showSearch = true
    @Published var showOverflow = true
    /// Whether the page has a status control to open at all.
    @Published var hasStatus = false
    /// The ⋯ menu, as the page published it. Empty means fall back to tapping
    /// the page's own ⋯ (an older page that publishes no menu).
    @Published var menu: [MenuSection] = []
    /// "dark" when the page is drawing light-on-dark, "light" otherwise, nil
    /// until the page has said. The bar follows the page, not the system.
    @Published var appearance: String?

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

    /// Runs JavaScript in the page. Installed by the web view's coordinator;
    /// nil until there is a page, in which case a tap does nothing.
    var runScript: ((String) -> Void)?

    /// Measures the bar for the page. Installed by the hosting controller.
    var reportInsets: ((@escaping (_ barInset: CGFloat, _ statusInset: CGFloat) -> Void) -> Void)?


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
        if payload.index(forKey: "subtitle") != nil {
            subtitle = payload["subtitle"] as? String ?? ""
        }
        if let value = payload["showMenu"] as? Bool { showMenu = value }
        if let value = payload["showSearch"] as? Bool { showSearch = value }
        if let value = payload["showOverflow"] as? Bool { showOverflow = value }
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
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.prefersLargeTitles = true
        root.navigationItem.largeTitleDisplayMode = .always
        root.bind(NativeHeaderModel.shared)
        return nav
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {
        (nav.viewControllers.first as? WebHostingController<Content>)?.rootView = content
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

/// The controller in the navigation stack. Renders `NativeHeaderModel` onto its
/// `navigationItem` and drives the large title from the web view's scrolling.
///
/// ## Why UIKit is handed a proxy and not the web view's own scroll view
///
/// The large-title machinery assumes the content scroll view is inset by the
/// bar: "at the top" means `contentOffset.y == -adjustedContentInset.top`,
/// where that inset is the *large* bar's height. The web view cannot be run
/// that way. Inset automatically, the page's layout viewport starts below the
/// bar and the band under the status bar shows the scroll view's black
/// backdrop rather than the page's wallpaper (measured, and it looked exactly
/// as bad as it sounds). Not inset, the page draws under the bar the way the
/// Home app's content does — but then its offset at rest is 0, UIKit reads
/// that as "scrolled 168pt under the bar" and the title never expands.
///
/// So UIKit gets a scroll view that *is* inset the way it expects — this
/// invisible proxy — and the proxy's offset is kept equal to the page's, one
/// KVO notification behind, on the same run loop turn. UIKit resizes the bar
/// from the proxy; the page never learns any of this happened. The one thing
/// UIKit would normally do to the content scroll view — snap it past the
/// half-collapsed title on release — it cannot do to a view nobody drags, so
/// `scrollViewDidEndDragging` below does that to the web view instead.
final class WebHostingController<Content: View>: UIHostingController<Content>, UIScrollViewDelegate {
    private var cancellable: AnyCancellable?
    private var offsetObservation: NSKeyValueObservation?
    private weak var webScrollView: UIScrollView?
    private let proxy = ProxyScrollView()
    /// The bar's inset with the large title shown / collapsed, as observed on
    /// the proxy. The difference is the band a release snaps across.
    private var largestInset: CGFloat = 0
    private var smallestInset: CGFloat = .greatestFiniteMagnitude

    override func viewDidLoad() {
        super.viewDidLoad()
        proxy.frame = view.bounds
        proxy.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        proxy.contentSize = CGSize(width: 1, height: 1_000_000)
        proxy.contentInsetAdjustmentBehavior = .always
        // Fully behind the web view, so it never sees a touch — and left
        // visible and interactive on purpose: UIKit ignores a content scroll
        // view it considers inert, and an alpha-0 proxy got a bar sized for a
        // large title with an empty large-title view (measured).
        proxy.backgroundColor = .clear
        proxy.showsVerticalScrollIndicator = false
        proxy.showsHorizontalScrollIndicator = false
        proxy.onAdjustedInsetChange = { [weak self] in self?.mirrorOffset() }
        view.insertSubview(proxy, at: 0)
    }

    /// The proxy is handed to UIKit only once the bar has been laid out large
    /// with no scroll view at all. Attached from the start, UIKit sized the
    /// bar for a large title but never moved the title control into the
    /// large-title view — it does that from scroll notifications, and a
    /// freshly attached scroll view at rest sends none (measured: an empty
    /// large-title view, the title parked inline at alpha 0).
    private var proxyAttached = false

    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        edge == .top && proxyAttached ? proxy : super.contentScrollView(for: edge)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachProxyIfNeeded()
    }

    private func attachProxyIfNeeded() {
        guard !proxyAttached else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.proxyAttached else { return }
            self.proxyAttached = true
            self.setContentScrollView(self.proxy, for: .top)
            self.mirrorOffset()
            self.nudgeProxy()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachWebScrollViewIfNeeded()
    }

    /// The web view is created by SwiftUI some time after this controller's
    /// view is; hook it the first time layout finds it.
    private func attachWebScrollViewIfNeeded() {
        guard webScrollView == nil, let scroll = Self.findWebScrollView(in: view) else { return }
        webScrollView = scroll
        scroll.delegate = self
        offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.mirrorOffset()
        }
        mirrorOffset()
    }

    /// Keep the proxy where the page is, in the proxy's own coordinate space.
    private func mirrorOffset() {
        let inset = proxy.adjustedContentInset.top
        if inset > 0 {
            largestInset = max(largestInset, inset)
            smallestInset = min(smallestInset, inset)
        }
        let pageY = max(0, webScrollView?.contentOffset.y ?? 0)
        var target = CGPoint(x: 0, y: -inset + pageY)
        // The page is at its top but UIKit has the title collapsed: only an
        // offset above the compact top reopens it, which is what a finger
        // pulling down would produce. Ask for the large-state top; UIKit
        // grows the inset to match and the next call lands exactly on it.
        if pageY == 0, inset < largestInset {
            target.y = -largestInset
        }
        if proxy.contentOffset != target {
            proxy.contentOffset = target
        }
    }

    /// The band across which the large title collapses: the difference between
    /// the two bar heights the proxy has been laid out at.
    private var collapseBand: CGFloat {
        guard largestInset > 0, smallestInset < largestInset else { return 52 }
        return largestInset - smallestInset
    }

    /// What UIKit does for its own scroll views: never leave the title half
    /// collapsed. Below halfway it reopens, above it finishes closing.
    private func snapIfNeeded(_ scroll: UIScrollView) {
        let y = scroll.contentOffset.y
        let band = collapseBand
        guard y > 0, y < band else { return }
        scroll.setContentOffset(CGPoint(x: 0, y: y < band / 2 ? 0 : band), animated: true)
    }

    // MARK: UIScrollViewDelegate (the web view's scroll view)

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { snapIfNeeded(scrollView) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        snapIfNeeded(scrollView)
    }

    /// The bar's height with the large title shown, and the status bar alone.
    /// The page pads its content by the first and pins its safe-area variable
    /// to the second.

    var barInsets: (bar: CGFloat, status: CGFloat) {
        let status = view.window?.safeAreaInsets.top ?? 0
        let bar = largestInset > 0 ? largestInset : view.safeAreaInsets.top
        return (bar, status)
    }

    private static func findWebScrollView(in view: UIView) -> UIScrollView? {
        if let web = view as? WKWebView { return web.scrollView }
        for sub in view.subviews {
            if let hit = findWebScrollView(in: sub) { return hit }
        }
        return nil
    }

    func bind(_ model: NativeHeaderModel) {
        model.reportInsets = { [weak self] completion in
            guard let self else { return }
            // After a layout pass, so a bar that has only just been shown has
            // its large-title height.
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
        navigationController?.setNavigationBarHidden(!model.enabled, animated: false)

        // Follow the page, not the system. The page draws light-on-dark over a
        // dark wallpaper or in its dark theme whatever the device is set to,
        // and a system-light bar over that is a black title on black. Scoped
        // to the bar (its menus inherit it) so the web view's own
        // `prefers-color-scheme` is left alone.
        // On the controller, not just the bar: the large title resolves its
        // colour against the controller's traits and stayed black over a dark
        // page with the override on the bar alone. The page does not read
        // `prefers-color-scheme` (its dark look is a class), so nothing in the
        // web view changes.
        let style: UIUserInterfaceStyle
        switch model.appearance {
        case "dark": style = .dark
        case "light": style = .light
        default: style = .unspecified
        }
        navigationController?.overrideUserInterfaceStyle = style
        let ink: UIColor? = style == .dark ? .white : style == .light ? .black : nil
        let attributes: [NSAttributedString.Key: Any]? = ink.map { [.foregroundColor: $0] }
        navigationController?.navigationBar.titleTextAttributes = attributes
        navigationController?.navigationBar.largeTitleTextAttributes = attributes
        navigationController?.navigationBar.tintColor = ink

        // Never empty: the bar builds its large-title content from the title
        // it has when it lays out, and an empty one at launch left the
        // large-title view with nothing in it even after the name arrived.
        let title = model.title.isEmpty ? "Homecast" : model.title
        if navigationItem.title != title {
            navigationItem.title = title
        }
        if #available(iOS 26.0, *) {
            navigationItem.subtitle = model.subtitle.isEmpty ? nil : model.subtitle
            navigationItem.largeSubtitle = model.subtitle.isEmpty ? nil : model.subtitle
        }

        // The Home app's title chevron: every home, the current one ticked.
        if #available(iOS 16.0, *) {
            let homes = model.homes
            let current = model.currentHomeId
            let hasStatus = model.hasStatus
            let subtitle = model.subtitle
            navigationItem.titleMenuProvider = homes.isEmpty && !hasStatus ? nil : { [weak model] _ in
                var children: [UIMenuElement] = homes.map { home in
                    UIAction(title: home.name, state: home.id == current ? .on : .off) { _ in
                        model?.selectHome(home.id)
                    }
                }
                if hasStatus {
                    let status = UIAction(
                        title: subtitle.isEmpty ? "Connection" : subtitle,
                        image: UIImage(systemName: "antenna.radiowaves.left.and.right")
                    ) { _ in model?.tap(.status) }
                    children.append(UIMenu(options: .displayInline, children: [status]))
                }
                return UIMenu(children: children)
            }
        }

        navigationItem.leftBarButtonItem = model.showMenu
            ? item("line.3.horizontal", label: "Menu") { model.tap(.menu) }
            : nil

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

        // Make the bar lay its title out now. Inside a representable the bar
        // is not on the layout path a title change would normally dirty: the
        // large-title view was created at the right size, alpha 1, with its
        // labels still at their zero frames — measured — so the title was
        // simply never painted.
        if let bar = navigationController?.navigationBar {
            Self.forceLayout(bar)
        }
        nudgeProxy()
    }

    /// UIKit places the title control (inline slot or large-title view) from
    /// its content scroll view's scroll notifications and from nothing else —
    /// a title that changes while the page rests at the top stays parked in
    /// the inline slot at alpha 0 until the user scrolls (measured). Two real
    /// offset changes, back to where it was, run that observer now.
    private func nudgeProxy() {
        guard proxyAttached else { return }
        // Past the top, never below it: a nudge downwards reads as the start
        // of a collapse and left the bar compact at rest (measured).
        let rest = proxy.contentOffset
        proxy.contentOffset = CGPoint(x: 0, y: rest.y - 1)
        proxy.contentOffset = rest
    }

    private static func forceLayout(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.subviews.forEach { forceLayout($0) }
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
