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
    /// The connection dot's colour, from the page's hex. nil hides the dot.
    @Published var statusColor: UIColor?
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
    /// A widget is expanded over the page. The bar stays — the page's own
    /// header stays reachable over a widget, and activating it dismisses the
    /// widget — but dimmed: it floats above the page's scrim, and undimmed it
    /// was the one thing on screen not behind it.
    @Published var dimmed = false

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
    /// The page has finished what a pull-to-refresh asked; set by the bar.
    var refreshDone: (() -> Void)?


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
        // Before anything lands: whether this message takes the page from
        // the home view onto a room, group or collection. The navigator
        // snapshots the home view in that instant — the page has posted this
        // before WebKit has drawn the new view, so what is on screen is still
        // the home (see `NativeHeaderNavigator`).
        let nextTitle = payload["title"] as? String ?? title
        let nextHeading = payload["heading"] as? String ?? heading
        // Only from a home that was actually showing: the first payload after
        // launch can land straight on a restored room, and what is on screen
        // then is the loading view, which is nothing to slide back to.
        if !title.isEmpty, !Self.isPage(heading: heading, title: title), Self.isPage(heading: nextHeading, title: nextTitle) {
            pageWillAppear?()
        }
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
            statusColor = (payload["statusColor"] as? String).flatMap(Self.color(hex:))
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
        if let value = payload["dimmed"] as? Bool { dimmed = value }
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

    /// `#rgb`, `#rrggbb` or `#rrggbbaa`. The page owns the palette and sends
    /// the colour rather than a name, so a new state needs no new build.
    static func color(hex: String) -> UIColor? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if text.count == 6 {
            r = CGFloat((value & 0xFF0000) >> 16) / 255; g = CGFloat((value & 0x00FF00) >> 8) / 255; b = CGFloat(value & 0x0000FF) / 255; a = 1
        } else {
            r = CGFloat((value & 0xFF000000) >> 24) / 255; g = CGFloat((value & 0x00FF0000) >> 16) / 255; b = CGFloat((value & 0x0000FF00) >> 8) / 255; a = CGFloat(value & 0x000000FF) / 255
        }
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    /// A page heading (room, group, collection) distinct from the home name.
    static func isPage(heading: String, title: String) -> Bool {
        let h = heading.trimmingCharacters(in: .whitespaces)
        return !h.isEmpty && h != title
    }

    var isOnPage: Bool { Self.isPage(heading: heading, title: title) }

    /// Called synchronously, from the message that moves the page onto a
    /// room, group or collection, before the new heading is stored.
    var pageWillAppear: (() -> Void)?
    /// The page has painted the view whose heading it last sent (an older
    /// page never says so; whoever waits on this needs a fallback).
    var painted: (() -> Void)?

    // MARK: - Back into the page

    /// The raw values are the wire format — they cross into JavaScript verbatim
    /// as `window.__homecastNativeHeader.tap('<rawValue>')`.
    enum Control: String {
        case menu, status, search, overflow
    }

    func tap(_ control: Control) {
        runScript?("window.__homecastNativeHeader && window.__homecastNativeHeader.tap('\(control.rawValue)');")
    }

    /// The native pull-to-refresh fired: `soft` for an ordinary refresh, `hard`
    /// for the deep pull that means the page's hard-reload countdown.
    func refresh(_ kind: String) {
        runScript?("window.__homecastNativeHeader && window.__homecastNativeHeader.refresh && window.__homecastNativeHeader.refresh('\(kind)');")
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
/// The status bar follows the page too.
///
/// Its style is decided by SwiftUI's root hosting controller, which never asks
/// a navigation controller embedded through a representable — so the bar's
/// own appearance override left the status bar reading the system: a black
/// clock and battery over a dark wallpaper. A preferred colour scheme is the
/// one lever SwiftUI exposes that reaches the status bar. `nil` is "no
/// preference", which is what every build without the bar gets. The page does
/// not read `prefers-color-scheme` (its dark look is a class), so nothing in
/// the web view changes.
struct NativeHeaderColorScheme: ViewModifier {
    @ObservedObject private var model = NativeHeaderModel.shared

    func body(content: Content) -> some View {
        content.preferredColorScheme(scheme)
    }

    private var scheme: ColorScheme? {
        guard model.enabled else { return nil }
        switch model.appearance {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}

struct NativeHeaderHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var navigator: NativeHeaderNavigator?
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let root = WebHostingController(rootView: content)
        let nav = UINavigationController(navigationBarClass: PassthroughNavigationBar.self, toolbarClass: nil)
        nav.viewControllers = [root]
        // Compact bar only; the large title is the controller's own view.
        nav.navigationBar.prefersLargeTitles = false
        root.navigationItem.largeTitleDisplayMode = .never
        root.bind(NativeHeaderModel.shared)
        context.coordinator.navigator = NativeHeaderNavigator(nav: nav, web: root, model: NativeHeaderModel.shared)
        return nav
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {
        // The web controller is the top of the stack, or under a ghost's
        // cover for a frame while a pop lands — never assume it is first.
        (nav.viewControllers.last(where: { $0 is WebHostingController<Content> }) as? WebHostingController<Content>)?.rootView = content
    }
}

/// The back button and the swipe back, on a room, group or collection.
///
/// The web view never moves and is never pushed. When the page reports a
/// heading, the navigator puts a *ghost* controller UNDER the web controller
/// — `[ghost, web]`, set without animation — showing a snapshot of the home
/// view taken in the instant before the page drew the room. From then on
/// UIKit does what it does for any second screen: draws the back button and
/// arms the interactive pop, and a tap or an edge swipe animates the room
/// sliding away over the home, exactly as a pushed screen would.
///
/// When the pop lands the stack is `[ghost]`. The snapshot is lifted out of
/// the ghost to cover the whole navigation view, the stack is put back to
/// `[web]` with no animation (the web view, still drawing the room, comes
/// back under the cover), and the page is told to go home. The page reports
/// the home heading once it has drawn it, and the cover fades. A cancelled
/// swipe leaves `[ghost, web]` as it was and nothing here runs.
///
/// Going home any other way — the title menu, the page's own controls —
/// takes the ghost out without animation: there is nothing to slide.
final class NativeHeaderNavigator: NSObject, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
    private weak var nav: UINavigationController?
    private weak var web: UIViewController?
    private let model: NativeHeaderModel
    private var cancellable: AnyCancellable?
    private var ghost: GhostController?
    // A bounded pan also works over WKWebView: its touch-action recognizers
    // can reject a UIScreenEdgePanGestureRecognizer before it begins. UIKit
    // still owns the interactive navigation transition.
    private lazy var homePan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panHome(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        return pan
    }()
    private var homeInteraction: UIPercentDrivenInteractiveTransition?
    private let homePictures: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 4
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// A UIKit interactive pop like room Back, with the outgoing home held in a
    /// picture while the single web view renders the home being revealed.
    private final class HomeSwipe {
        let fromID: String
        let toID: String
        let offset: CGFloat
        let overlay: UIView
        let destination: GhostController
        var cancelled = false
        var landed = false
        var readyID: String?
        var renderingID: String?
        var timeout: DispatchWorkItem?
        var expectedID: String { cancelled ? fromID : toID }

        init(fromID: String, toID: String, offset: CGFloat, overlay: UIView, destination: GhostController) {
            self.fromID = fromID
            self.toID = toID
            self.offset = offset
            self.overlay = overlay
            self.destination = destination
        }
    }
    private var homeSwipe: HomeSwipe?
    /// The home view, captured as the page left it for a room: one copy to
    /// slide away for the push, one for the ghost to stand behind the pop.
    private var pendingSnapshot: UIView?
    private var pendingPushCover: UIView?
    /// Where the home was scrolled to when the snapshot was taken, so the
    /// live home comes back under the cover in the same place and nothing
    /// jumps when the cover lifts. nil when there was no snapshot.
    private var pendingHomeOffset: CGFloat?
    private var homeOffset: CGFloat?
    /// Whether the home's compact title was showing when it was captured (the
    /// home scrolled past its large title). The ghost carries a look-alike
    /// of it then, so the home's name is in the bar from the first frame of
    /// the pop — the bar cross-fades the room's title into it — instead of
    /// arriving with the live home a beat after the pop has landed.
    private var pendingHomeInlineTitle = false
    private var cover: UIView?
    private var coverTimeout: DispatchWorkItem?
    /// The push, waiting for the page to say the room is painted (or for
    /// the fallback timer — an older page never says). A closure and a
    /// separate timer, not one work item: a cancelled DispatchWorkItem's
    /// `perform` is a no-op, so cancelling the timer and then performing it
    /// started nothing, and the home's cover stayed on screen for good.
    private var pendingPushStart: (() -> Void)?
    private var pendingPushFallback: DispatchWorkItem?
    /// The pop's cover, waiting for the page to say the home is painted: the
    /// heading arrives from the page's first render, and the grid follows in
    /// a deferred one — lifted on the heading, the cover came off a home
    /// still showing the room's tiles under the home's title, with no pills
    /// and no section headings, for a beat.
    private var pendingLift: (() -> Void)?
    private var pendingLiftFallback: DispatchWorkItem?

    private func pagePainted() {
        if homeSwipe != nil {
            renderHomeSwipe()
            return
        }
        if let start = pendingPushStart {
            pendingPushStart = nil
            pendingPushFallback?.cancel()
            pendingPushFallback = nil
            start()
            return
        }
        if let lift = pendingLift {
            pendingLift = nil
            pendingLiftFallback?.cancel()
            pendingLiftFallback = nil
            lift()
        }
    }
    private var wasOnPage = false
    /// The page has been told to go home; the next report of the home
    /// heading (and the paint after it) lifts the cover.
    private var awaitingHome = false
    /// The room, pictured, laid over the web view from the moment the pop is
    /// certain to land until it has: the page is told to go home THEN, not
    /// when the pop lands, so the home renders under the picture while the
    /// room slides away — and the wait to scroll after landing is the pop's
    /// own animation shorter. A tap on the back button is certain at once;
    /// a swipe once the finger lifts without cancelling.
    private var roomOverlay: UIView?
    /// The home was painted before the pop landed: no cover needed then.
    private var homePaintedEarly = false

    init(nav: UINavigationController, web: UIViewController, model: NativeHeaderModel) {
        self.nav = nav
        self.web = web
        self.model = model
        super.init()
        nav.delegate = self
        nav.view.addGestureRecognizer(homePan)
        nav.interactivePopGestureRecognizer?.require(toFail: homePan)
        if #available(iOS 26.0, *) {
            nav.interactiveContentPopGestureRecognizer?.require(toFail: homePan)
        }
        (nav.navigationBar as? PassthroughNavigationBar)?.showTitle((web as? NativeHeaderTitleProviding)?.compactHeaderTitle)
        model.pageWillAppear = { [weak self] in self?.capture() }
        model.painted = { [weak self] in self?.pagePainted() }
        cancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.apply() }
            }
    }

    /// The home view as it is on screen right now, as an image (see
    /// `PageSnapshotting`): the page's message arrived before WebKit's next
    /// frame, so what is presented is still the home. An image and not
    /// `snapshotView`'s replicant — a replicant only holds its picture while
    /// it stays in a window, and both a copy kept aside for the ghost and one
    /// re-parented into it after the push came up blank grey.
    private func capture() {
        // The sidebar already provides navigation in the wide layout. Leave
        // its selections to the web page's existing transition; only the
        // compact, large-title layout pushes a room over the whole home.
        guard model.enabled, model.largeTitle else { return }
        // A home has its previous neighbour underneath it solely for the
        // edge gesture. A room needs the current home underneath instead.
        if ghost?.homeID != nil, homeSwipe == nil, let nav, let web {
            ghost = nil
            homePan.isEnabled = false
            web.navigationItem.hidesBackButton = false
            nav.setViewControllers([web], animated: false)
        }
        guard let web, web.isViewLoaded, ghost == nil, cover == nil else { return }
        guard let page = web as? PageSnapshotting, let image = page.snapshotImage() else { return }
        pendingSnapshot = Self.still(image)
        pendingPushCover = Self.still(image)
        pendingHomeOffset = page.pageOffset
        pendingHomeInlineTitle = page.inlineTitleAlpha > 0.5
        // From here until the slide has run, the bar's title is held: the
        // page controller applies the room's title on the same message as
        // this, and an unheld title switched to the room's name — centred
        // in the bar, over a cover still showing the home — before anything
        // had moved. And the page starts the room at its top: the document
        // keeps its offset across the change, so a room opened from a
        // scrolled home came in scrolled, its large title already gone, and
        // then clamped to the top when its shorter content had laid out.
        page.setPushing(true)
        page.restorePageOffset(0)
    }

    private static func still(_ image: UIImage) -> UIView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }

    private func apply() {
        guard let nav, let web else { return }
        guard homeSwipe == nil else { return }
        let onPage = model.enabled && model.largeTitle && model.isOnPage
        defer { wasOnPage = onPage }

        if awaitingHome, !model.isOnPage {
            // The page has reported the home view. Once it says it has
            // painted it (or after a beat, for a page that never says), put
            // it back where the snapshot shows it and lift the cover.
            awaitingHome = false
            let target = homeOffset
            homeOffset = nil
            let lift: () -> Void = { [weak self, weak web] in
                guard let self else { return }
                if self.ghost != nil {
                    // Still sliding: the home is ready before the pop has
                    // landed. Put it in place now; the landing skips the cover.
                    self.homePaintedEarly = true
                    if let target, let page = web as? PageSnapshotting {
                        self.restoreThenLift(page: page, offset: target, attempts: 24)
                    }
                    return
                }
                let flat = !(self.cover is UIImageView)
                if let target, let page = web as? PageSnapshotting {
                    self.restoreThenLift(page: page, offset: target, attempts: 24)
                } else {
                    // A flat cover (the app opened straight onto the room):
                    // there is no picture to match, so it goes at once.
                    self.liftCover(immediately: flat)
                }
            }
            pendingLift = lift
            pendingLiftFallback?.cancel()
            let fallback = DispatchWorkItem { [weak self] in self?.pagePainted() }
            pendingLiftFallback = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: fallback)
        }

        if onPage, !wasOnPage, ghost == nil, nav.viewControllers == [web] {
            // The colour is read when the ghost is first shown, not now: at
            // launch the page has not yet told the web view its canvas colour
            // when the first heading arrives, and a ghost coloured then was
            // black behind the pop.
            let ghost = GhostController(snapshot: pendingSnapshot, fallback: { [weak web] in
                web.map { Self.backdropColor(of: $0.view) } ?? .systemBackground
            })
            pendingSnapshot = nil
            homeOffset = pendingHomeOffset
            pendingHomeOffset = nil
            // A bare chevron, like the page's own crumbs: the compact title
            // already names the home under the room.
            ghost.navigationItem.backButtonDisplayMode = .minimal
            // The bar's title during the pop: the home's compact title if the
            // home had scrolled past its large one (a look-alike, so the name
            // is there from the first frame and the swap to the live one is
            // invisible), and nothing otherwise — the large name is in the
            // picture, and a title in the bar for the length of the pop that
            // vanished when it landed read as a flash.
            ghost.navigationItem.title = nil
            if pendingHomeInlineTitle, let page = web as? PageSnapshotting {
                ghost.compactHeaderTitle = page.compactTitleLookalike(model.title)
            }
            pendingHomeInlineTitle = false
            // The same trailing buttons the web controller shows, as
            // look-alikes: the bar animates between the two navigation items
            // during the pop, and a ghost with no items had the search and ⋯
            // buttons slide out for the pop and back in when the stack was
            // put right, which read as a glitch. Look-alikes rather than the
            // web's own items — a bar button item belongs to one navigation
            // item at a time. Inert: the stack is back to the web controller
            // within a frame of the pop landing.
            ghost.navigationItem.rightBarButtonItems = (web.navigationItem.rightBarButtonItems ?? []).map { item in
                let twin = UIBarButtonItem(image: item.image, style: .plain, target: nil, action: nil)
                twin.accessibilityLabel = item.accessibilityLabel
                twin.tintColor = item.tintColor ?? nav.navigationBar.tintColor
                return twin
            }
            self.ghost = ghost
            if let pushCover = pendingPushCover {
                pendingPushCover = nil
                animatePush(from: pushCover, settingStack: [ghost, web])
            } else {
                nav.setViewControllers([ghost, web], animated: false)
                (web as? PageSnapshotting)?.setPushing(false)
            }
        } else if !onPage, ghost != nil, ghost?.homeID == nil, !awaitingHome, nav.viewControllers.count == 2 {
            // Home by some other road: no pop to animate.
            nav.setViewControllers([web], animated: false)
            ghost = nil
            pendingSnapshot = nil
            pendingPushCover = nil
            pendingHomeOffset = nil
            homeOffset = nil
        } else if !onPage {
            if pendingPushCover != nil { (web as? PageSnapshotting)?.setPushing(false) }
            pendingSnapshot = nil
            pendingPushCover = nil
            pendingHomeOffset = nil
        }
        if !onPage { prepareHomeSwipe() }
    }

    private var previousHome: NativeHeaderModel.Home? {
        guard model.enabled, model.largeTitle, model.showMenu, !model.isOnPage,
              let current = model.currentHomeId, model.homes.count > 1,
              let index = model.homes.firstIndex(where: { $0.id == current }) else { return nil }
        return model.homes[(index + model.homes.count - 1) % model.homes.count]
    }

    private func pictureKey(_ id: String) -> NSString {
        let size = nav?.view.bounds.size ?? .zero
        return "\(id):\(Int(size.width))x\(Int(size.height))" as NSString
    }

    private func cacheHomePicture(_ image: UIImage, id: String) {
        homePictures.setObject(image, forKey: pictureKey(id),
                               cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
    }

    private func prepareHomeSwipe() {
        guard let nav, let web, homeSwipe == nil, cover == nil,
              !awaitingHome, roomOverlay == nil, nav.transitionCoordinator == nil,
              nav.topViewController === web, ghost == nil || ghost?.homeID != nil else { return }
        guard let previous = previousHome else {
            homePan.isEnabled = false
            if ghost?.homeID != nil {
                ghost = nil
                nav.setViewControllers([web], animated: false)
            }
            web.navigationItem.hidesBackButton = false
            return
        }
        web.navigationItem.hidesBackButton = true
        if ghost?.homeID != previous.id {
            let image = homePictures.object(forKey: pictureKey(previous.id))
            let destination = GhostController(snapshot: image.map(Self.still), fallback: { [weak web] in
                web.map { Self.backdropColor(of: $0.view) } ?? .systemBackground
            })
            destination.homeID = previous.id
            destination.navigationItem.hidesBackButton = true
            destination.navigationItem.rightBarButtonItems = (web.navigationItem.rightBarButtonItems ?? []).map { item in
                let ink = item.tintColor ?? nav.navigationBar.tintColor ?? .label
                let image = item.image?.withTintColor(ink, renderingMode: .alwaysOriginal)
                let twin = UIBarButtonItem(image: image, style: .plain, target: nil, action: nil)
                twin.accessibilityLabel = item.accessibilityLabel
                twin.tintColor = ink
                return twin
            }
            ghost = destination
            nav.setViewControllers([destination, web], animated: false)
        }
        homePan.isEnabled = true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === homePan, let nav, previousHome != nil,
              !model.covered, !model.dimmed, homeSwipe == nil, cover == nil,
              nav.transitionCoordinator == nil, nav.viewControllers.count == 2 else { return false }
        let velocity = homePan.velocity(in: nav.view)
        return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
    }

    @objc private func panHome(_ pan: UIPanGestureRecognizer) {
        guard let nav else { return }
        let width = max(1, nav.view.bounds.width)
        let progress = min(1, max(0, pan.translation(in: nav.view).x / width))
        switch pan.state {
        case .began:
            let interaction = UIPercentDrivenInteractiveTransition()
            interaction.completionCurve = .easeOut
            homeInteraction = interaction
            nav.popViewController(animated: true)
        case .changed:
            homeInteraction?.update(progress)
        case .ended:
            let projected = progress + pan.velocity(in: nav.view).x / width * 0.2
            if projected > 0.5 { homeInteraction?.finish() }
            else { homeInteraction?.cancel() }
        case .cancelled, .failed:
            homeInteraction?.cancel()
        default: break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let x = touch.location(in: nav?.view).x
        return gestureRecognizer === homePan && x >= 0 && x <= 24
    }

    /// UIKit owns progress, completion and cancellation. The content uses
    /// the same pop geometry as room Back: foreground moves one screen,
    /// destination moves a third, with the same leading shadow and dimming.
    private final class HomePopAnimator: NSObject, UIViewControllerAnimatedTransitioning {
        func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { 0.35 }

        func animateTransition(using context: UIViewControllerContextTransitioning) {
            guard let from = context.view(forKey: .from), let to = context.view(forKey: .to),
                  let destination = context.viewController(forKey: .to) else {
                context.completeTransition(false)
                return
            }
            let container = context.containerView
            let width = container.bounds.width
            to.frame = context.finalFrame(for: destination)
            container.insertSubview(to, belowSubview: from)
            to.transform = CGAffineTransform(translationX: -width / 3, y: 0)
            let veil = UIView(frame: to.bounds)
            veil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            veil.backgroundColor = .black
            veil.alpha = 0.12
            to.addSubview(veil)
            let shadow = UIView(frame: from.frame)
            shadow.backgroundColor = .black
            shadow.layer.shadowColor = UIColor.black.cgColor
            shadow.layer.shadowOpacity = 0.12
            shadow.layer.shadowRadius = 8
            shadow.layer.shadowOffset = CGSize(width: -3, height: 0)
            container.insertSubview(shadow, belowSubview: from)
            UIView.animate(withDuration: transitionDuration(using: context), delay: 0, options: [.curveLinear], animations: {
                from.transform = CGAffineTransform(translationX: width, y: 0)
                shadow.transform = from.transform
                to.transform = .identity
                veil.alpha = 0
            }, completion: { _ in
                let completed = !context.transitionWasCancelled
                veil.removeFromSuperview()
                shadow.removeFromSuperview()
                from.transform = .identity
                to.transform = .identity
                context.completeTransition(completed)
            })
        }
    }

    func navigationController(_ navigationController: UINavigationController, animationControllerFor operation: UINavigationController.Operation, from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard operation == .pop, homeInteraction != nil, (toVC as? GhostController)?.homeID != nil else { return nil }
        return HomePopAnimator()
    }

    func navigationController(_ navigationController: UINavigationController, interactionControllerFor animationController: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        animationController is HomePopAnimator ? homeInteraction : nil
    }

    private func beginHomeSwipe(to destination: GhostController) {
        guard homeSwipe == nil, let web, let page = web as? PageSnapshotting,
              let fromID = model.currentHomeId, let toID = destination.homeID,
              let image = page.snapshotImage() else { return }
        // Home cycling starts at the top. Never reuse a scrolled picture as
        // that destination, or it would jump when the live page replaces it.
        if abs(page.pageOffset) < 0.5 { cacheHomePicture(image, id: fromID) }
        let overlay = Self.still(image)
        overlay.frame = web.view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.view.addSubview(overlay)
        let swipe = HomeSwipe(fromID: fromID, toID: toID, offset: page.pageOffset, overlay: overlay, destination: destination)
        homeSwipe = swipe
        page.setPushing(true)
        page.restorePageOffset(0)
        model.selectHome(toID)
        scheduleHomePaintFallback(swipe)
    }

    private func scheduleHomePaintFallback(_ swipe: HomeSwipe) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak swipe] in
            guard let self, let swipe, self.homeSwipe === swipe else { return }
            self.renderHomeSwipe()
        }
    }

    private func renderHomeSwipe() {
        guard let swipe = homeSwipe, let page = web as? PageSnapshotting,
              model.currentHomeId == swipe.expectedID, !model.isOnPage,
              swipe.readyID != swipe.expectedID, swipe.renderingID != swipe.expectedID else { return }
        let expected = swipe.expectedID
        swipe.renderingID = expected
        page.restorePageOffset(swipe.cancelled ? swipe.offset : 0)
        page.renderedSnapshotImage { [weak self, weak swipe] image in
            guard let self, let swipe, self.homeSwipe === swipe else { return }
            swipe.renderingID = nil
            guard swipe.expectedID == expected, self.model.currentHomeId == expected else { return }
            if !swipe.cancelled, let image {
                self.cacheHomePicture(image, id: expected)
                swipe.destination.replaceSnapshot(Self.still(image))
            }
            swipe.readyID = expected
            self.finishHomeSwipeIfReady()
        }
    }

    private func finishHomeSwipeIfReady(force: Bool = false) {
        guard let swipe = homeSwipe, swipe.landed,
              force || swipe.readyID == swipe.expectedID, let nav, let web else { return }
        swipe.timeout?.cancel()
        // Hold the destination over the stack reset, as on a room pop. The
        // outgoing picture stays attached to the moving controller until
        // the gesture finishes, including throughout a cancelled swipe.
        if !swipe.cancelled {
            let destination = swipe.destination.takeSnapshot()
            destination.frame = nav.view.bounds
            destination.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            nav.view.insertSubview(destination, belowSubview: nav.navigationBar)
            cover = destination
        }
        homeSwipe = nil
        ghost = nil
        UIView.performWithoutAnimation {
            swipe.overlay.removeFromSuperview()
            nav.setViewControllers([web], animated: false)
            (web as? PageSnapshotting)?.setPushing(false)
            nav.navigationBar.layoutIfNeeded()
        }
        liftCover()
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    /// The push, drawn by hand: UIKit will not animate a stack change that
    /// keeps the same controller on top. Two snapshots do it — the home, taken
    /// as the page left it, and the room, taken once WebKit has drawn it —
    /// and the room slides in over the home, which slides a third of the way
    /// off under a dimming veil, as UIKit's own push does. Snapshots rather
    /// than the web view itself: a WKWebView translated off screen only paints
    /// the tiles it thinks are visible, so sliding the live view in showed the
    /// room arriving in pieces.
    private func animatePush(from home: UIView, settingStack stack: [UIViewController]) {
        guard let nav, let web else { return }
        let width = nav.view.bounds.width
        home.frame = nav.view.bounds
        home.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let veil = UIView(frame: home.bounds)
        veil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        veil.backgroundColor = .black
        veil.alpha = 0
        home.addSubview(veil)
        nav.view.insertSubview(home, belowSubview: nav.navigationBar)
        cover = home
        // Until the page says it has painted the room (once the document has
        // been still for two frames, at most 600ms after the heading), or a
        // little longer than that has passed for a page that never says, the
        // home snapshot covers the screen. Then the room is snapshotted
        // and the pair animate. `afterScreenUpdates: true` so the picture is
        // of the room as drawn, not the frame before it. A picture taken on a
        // fixed short delay slid in blank on a slow page, and the room then
        // "appeared" after the slide.
        let start: () -> Void = { [weak self, weak web, weak nav] in
            guard let self, let web, let nav else { return }
            self.pendingPushStart = nil
            self.pendingPushFallback = nil
            guard self.cover === home else {
                if nav.viewControllers != stack { nav.setViewControllers(stack, animated: false) }
                (web as? PageSnapshotting)?.setPushing(false)
                return
            }
            // The room, as WebKit paints it — asked of WebKit, not copied from
            // the screen (see `renderedSnapshotImage`).
            guard let page = web as? PageSnapshotting else {
                nav.setViewControllers(stack, animated: false)
                home.removeFromSuperview()
                self.cover = nil
                return
            }
            page.renderedSnapshotImage { [weak self, weak web, weak nav] image in
            guard let self, let web, let nav, self.cover === home, let image else {
                if let nav, nav.viewControllers != stack { nav.setViewControllers(stack, animated: false) }
                home.removeFromSuperview()
                if self?.cover === home { self?.cover = nil }
                (web as? PageSnapshotting)?.setPushing(false)
                return
            }
            let room = Self.still(image)
            room.frame = nav.view.bounds
            room.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            room.transform = CGAffineTransform(translationX: width, y: 0)
            // The shadow UIKit draws down the incoming screen's leading edge.
            room.layer.shadowColor = UIColor.black.cgColor
            room.layer.shadowOpacity = 0.12
            room.layer.shadowRadius = 8
            room.layer.shadowOffset = CGSize(width: -3, height: 0)
            nav.view.insertSubview(room, aboveSubview: home)
            // UIKit's own push: about a third of a second, critically damped.
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0.6, options: [.allowUserInteraction], animations: {
                // Inside the block, so the bar's own changes — the back
                // button arriving — ease in with the slide rather than
                // landing a beat before it.
                nav.setViewControllers(stack, animated: false)
                nav.navigationBar.layoutIfNeeded()
                room.transform = .identity
                home.transform = CGAffineTransform(translationX: -width / 3, y: 0)
                veil.alpha = 0.12
            }, completion: { _ in
                room.removeFromSuperview()
                home.removeFromSuperview()
                if self.cover === home { self.cover = nil }
                (web as? PageSnapshotting)?.setPushing(false)
            })
            }
        }
        pendingPushFallback?.cancel()
        pendingPushStart = start
        let fallback = DispatchWorkItem { [weak self] in self?.pagePainted() }
        pendingPushFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: fallback)
    }

    // MARK: UINavigationControllerDelegate


    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        let bar = navigationController.navigationBar as? PassthroughNavigationBar
        bar?.showTitle((viewController as? NativeHeaderTitleProviding)?.compactHeaderTitle, animated: animated)
        if let coordinator = navigationController.transitionCoordinator, coordinator.isInteractive {
            coordinator.notifyWhenInteractionChanges { [weak self, weak bar] context in
                if context.isCancelled {
                    bar?.showTitle((self?.web as? NativeHeaderTitleProviding)?.compactHeaderTitle, animated: true)
                }
            }
        }
        if let destination = viewController as? GhostController, destination.homeID != nil, animated {
            beginHomeSwipe(to: destination)
            if let swipe = homeSwipe, let coordinator = navigationController.transitionCoordinator {
                coordinator.notifyWhenInteractionChanges { [weak self, weak swipe] context in
                    guard let self, let swipe, self.homeSwipe === swipe else { return }
                    if context.isCancelled {
                        swipe.cancelled = true
                        swipe.readyID = nil
                        self.model.selectHome(swipe.fromID)
                        self.scheduleHomePaintFallback(swipe)
                    }
                }
            }
            return
        }
        guard let ghost, viewController === ghost, animated else { return }
        // A pop towards the ghost has begun. Send the page home as soon as
        // the pop is certain to land: now for a tap on the back button, or
        // when a swipe's finger lifts without cancelling.
        guard let coordinator = navigationController.transitionCoordinator else { return }
        if coordinator.isInteractive {
            coordinator.notifyWhenInteractionChanges { [weak self] context in
                if !context.isCancelled { self?.sendHomeEarly() }
            }
        } else {
            sendHomeEarly()
        }
    }

    private func sendHomeEarly() {
        guard !awaitingHome, let web, let page = web as? PageSnapshotting else { return }
        awaitingHome = true
        homePaintedEarly = false
        // The room's picture over the web view first, so the page can change
        // underneath it while the room is still sliding.
        page.renderedSnapshotImage { [weak self, weak web] image in
            guard let self, let web else { return }
            if let image {
                let overlay = Self.still(image)
                overlay.frame = web.view.bounds
                overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                web.view.addSubview(overlay)
                self.roomOverlay = overlay
            }
            self.model.navigate("home:")
        }
        // However the page answers, nothing here outstays it.
        let timeout = DispatchWorkItem { [weak self] in
            self?.awaitingHome = false
            self?.pendingLift = nil
            self?.pendingLiftFallback?.cancel()
            self?.pendingLiftFallback = nil
            self?.roomOverlay?.removeFromSuperview()
            self?.roomOverlay = nil
            self?.liftCover()
        }
        coverTimeout?.cancel()
        coverTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        (navigationController.navigationBar as? PassthroughNavigationBar)?.showTitle((viewController as? NativeHeaderTitleProviding)?.compactHeaderTitle)
        if let swipe = homeSwipe {
            homeInteraction = nil
            swipe.landed = true
            swipe.cancelled = viewController === web
            let timeout = DispatchWorkItem { [weak self, weak swipe] in
                guard let self, let swipe, self.homeSwipe === swipe else { return }
                self.finishHomeSwipeIfReady(force: true)
            }
            swipe.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
            finishHomeSwipeIfReady()
            return
        }
        // An idle home also has a ghost underneath. It is not a room Back.
        if ghost?.homeID != nil { return }
        guard let ghost, viewController === ghost, let web, let nav else { return }
        // The pop has landed: the ghost is all that is on the stack.
        self.ghost = nil
        if homePaintedEarly {
            // The home was drawn while the room slid away: nothing to hide.
            homePaintedEarly = false
            UIView.performWithoutAnimation {
                nav.setViewControllers([web], animated: false)
                nav.navigationBar.layoutIfNeeded()
            }
            roomOverlay?.removeFromSuperview()
            roomOverlay = nil
            DispatchQueue.main.async { [weak self] in self?.apply() }
            return
        }
        let snapshot = ghost.takeSnapshot()
        snapshot.frame = nav.view.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        nav.view.insertSubview(snapshot, belowSubview: nav.navigationBar)
        cover = snapshot
        // Without implicit animation, or the bar cross-fades the ghost's
        // look-alike buttons into the web controller's real ones — a second
        // fade on top of the pop's own.
        UIView.performWithoutAnimation {
            nav.setViewControllers([web], animated: false)
            nav.navigationBar.layoutIfNeeded()
        }
        // Under the cover now; the room's picture has done its job.
        roomOverlay?.removeFromSuperview()
        roomOverlay = nil
        if !awaitingHome {
            // The early send did not happen (a pop that was not animated);
            // send now.
            sendHomeEarly()
        }
    }

    /// Tries the offset once a frame (up to `attempts`, about 400ms), and
    /// lifts the cover as soon as it takes — or when time is up, at the top.
    private func restoreThenLift(page: PageSnapshotting, offset: CGFloat, attempts: Int) {
        if page.restorePageOffset(offset) || attempts <= 0 {
            liftCover()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self, weak page] in
            guard let self, let page else { return }
            self.restoreThenLift(page: page, offset: offset, attempts: attempts - 1)
        }
    }

    private func liftCover(immediately: Bool = false) {
        coverTimeout?.cancel()
        coverTimeout = nil
        roomOverlay?.removeFromSuperview()
        roomOverlay = nil
        guard let cover else {
            DispatchQueue.main.async { [weak self] in self?.prepareHomeSwipe() }
            return
        }
        self.cover = nil
        if immediately {
            cover.removeFromSuperview()
            DispatchQueue.main.async { [weak self] in self?.prepareHomeSwipe() }
            return
        }
        // A frame for WebKit to present the home view (the page pads for the
        // room's eyebrow itself now, so nothing moves later), then a short
        // fade so a stale detail or two (a light that changed) dissolves
        // rather than pops. Short: until the cover is gone the page under it
        // reads as not yet scrollable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            UIView.animate(withDuration: 0.12, animations: { cover.alpha = 0 }) { [weak self] _ in
                cover.removeFromSuperview()
                self?.prepareHomeSwipe()
            }
        }
    }

    /// The colour the page has asked the web view to paint under itself —
    /// what the ghost shows when there was no snapshot to take (the app
    /// opened straight onto a room).
    private static func backdropColor(of view: UIView) -> UIColor {
        func find(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        // The page sets both when it publishes its canvas colour; the scroll
        // view's is the one that shows through under the content.
        if let web = find(view) {
            if let color = web.scrollView.backgroundColor ?? web.backgroundColor { return color }
        }
        return .systemBackground
    }

    /// Stands in for the home view under the web controller: a snapshot of
    /// it, or the page's backdrop colour.
    final class GhostController: UIViewController, NativeHeaderTitleProviding {
        var homeID: String?
        var compactHeaderTitle: UIView?
        private var snapshot: UIView?
        private let fallback: () -> UIColor

        init(snapshot: UIView?, fallback: @escaping () -> UIColor) {
            self.snapshot = snapshot
            self.fallback = fallback
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = fallback()
            if let snapshot {
                snapshot.frame = view.bounds
                snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(snapshot)
            }
        }

        /// Read again as the pop begins: UIKit may load this view while the
        /// web view is still on its launch colour, and the pop is when the
        /// colour matters.
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            view.backgroundColor = fallback()
        }

        func replaceSnapshot(_ replacement: UIView) {
            snapshot?.removeFromSuperview()
            snapshot = replacement
            if isViewLoaded {
                replacement.frame = view.bounds
                replacement.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.insertSubview(replacement, at: 0)
            }
        }

        /// Hands the snapshot over (to become the cover), leaving the flat
        /// colour behind.
        func takeSnapshot() -> UIView {
            if let snapshot {
                self.snapshot = nil
                snapshot.removeFromSuperview()
                return snapshot
            }
            let flat = UIView()
            flat.backgroundColor = fallback()
            return flat
        }
    }
}

/// A navigation bar that, when asked, is nothing but its buttons: touches
/// anywhere else fall through to the content beneath. Used in the sidebar
/// layout, where the bar has no title and no background and the content it
/// floats over must stay tappable.
final class PassthroughNavigationBar: UINavigationBar {
    var passesThrough = false
    private let titleContainer = UIView()
    private weak var centeredTitle: UIView?

    // Own the title's placement. iOS 26's titleView layout differs between a
    // fresh root item and an item returned from a room; an invisible leading
    // bar item balances it but gets morphed into a box by the back animation.
    // The title has no glass of its own, so keep it outside those item groups.
    func showTitle(_ title: UIView?, animated: Bool = false) {
        if titleContainer.superview == nil { addSubview(titleContainer) }
        guard centeredTitle !== title else { setNeedsLayout(); return }
        let replace = {
            self.centeredTitle?.removeFromSuperview()
            self.centeredTitle = title
            if let title { self.titleContainer.addSubview(title) }
            self.layoutCenteredTitle()
        }
        if animated {
            UIView.transition(with: titleContainer, duration: 0.2,
                              options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
                              animations: replace)
        } else {
            UIView.performWithoutAnimation(replace)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCenteredTitle()
        if titleContainer.superview === self { bringSubviewToFront(titleContainer) }
    }

    private func layoutCenteredTitle() {
        guard let title = centeredTitle else { titleContainer.frame = .zero; return }
        let size = title.intrinsicContentSize
        titleContainer.frame = CGRect(x: (bounds.width - size.width) / 2,
                                      y: (min(bounds.height, 44) - size.height) / 2,
                                      width: size.width, height: size.height)
        title.frame = titleContainer.bounds
        title.setNeedsLayout()
        title.layoutIfNeeded()
    }

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
    /// On a room, group or collection page the home's name sits as a small
    /// line above the big name; the band grows by this much to hold it.
    static let eyebrowHeight: CGFloat = 18
    /// The bar's alpha while a widget is expanded over the page.
    static let dimmedAlpha: CGFloat = 0.35
    /// How far past the top a pull has to go to mean the hard reload rather
    /// than a refresh — roughly what a 500px finger travel came to on the
    /// web control once the scroll view's rubber band is accounted for.
    static let hardPull: CGFloat = 200
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
/// What the navigator needs of the page's controller for its transitions:
/// a picture of the page as it is on screen, and a way to hold the bar's
/// title still while a push is drawn.
protocol NativeHeaderTitleProviding: AnyObject {
    var compactHeaderTitle: UIView? { get }
}

protocol PageSnapshotting: NativeHeaderTitleProviding {
    func snapshotImage() -> UIImage?
    /// The page as WebKit would paint it now, asked of WebKit itself. For a
    /// view that has only just been laid out: UIKit's snapshot of a web view
    /// copies whatever tiles WebKit has rasterised so far, and a room taken
    /// that way slid in as glass boxes with no icons or text, which arrived
    /// when the slide stopped. Slower (a round trip to the web process), so
    /// not for the home capture, which must copy the frame on screen before
    /// the page changes.
    func renderedSnapshotImage(completion: @escaping (UIImage?) -> Void)
    /// While true the inline title keeps its text and fades out over the
    /// push instead of switching to the new page's the instant the page
    /// reports it — under the cover the content is still the old page, and
    /// a bar that changed first read as a jump. Ending it applies whatever
    /// arrived meanwhile.
    func setPushing(_ pushing: Bool)
    /// The page's scroll offset, so a pop can put the home back where the
    /// snapshot shows it.
    var pageOffset: CGFloat { get }
    /// The compact title's alpha — 1 once the page has scrolled the large
    /// title away, 0 at the top.
    var inlineTitleAlpha: CGFloat { get }
    /// An inert copy of the compact title showing `title`, built and sized
    /// the way the live one is, so the bar places both identically and the
    /// hand-over from one to the other moves nothing.
    func compactTitleLookalike(_ title: String) -> UIView
    /// Scrolls to `offset` if the page is tall enough to reach it, and says
    /// whether it was. The home's content arrives over a few frames after
    /// the page reports the heading; asked too early, the scroll view clamps
    /// to the short page and the offset is lost.
    @discardableResult
    func restorePageOffset(_ offset: CGFloat) -> Bool
}

final class WebHostingController<Content: View>: UIHostingController<Content>, PageSnapshotting {
    private var cancellable: AnyCancellable?
    private var offsetObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?
    /// Samples the page's offset every frame while it is moving. WebKit's
    /// scroll view does not post an offset change for every frame of a drag
    /// or a fling, so a title driven by notifications alone lagged behind by
    /// up to a second (reported). A display link is what a scroll-linked
    /// effect needs; it is paused whenever the page is still.
    private var displayLink: CADisplayLink?
    private var lastSampledOffset: CGFloat = .nan
    private var stillFrames = 0
    private weak var webScrollView: UIScrollView?
    private let proxy = ProxyScrollView()
    /// The compact bar's inset (status bar + bar), as observed while shown.
    private var compactInset: CGFloat = 0
    /// The large text is a page heading (a room, group or collection), not
    /// the home name: the bar's title stays put and nothing crossfades.
    private var headingIsPage = false
    /// Mirrors `NativeHeaderModel.largeTitle`.
    private var largeTitleEnabled = true
    /// A push is being drawn: the inline title is held (see `setPushing`).
    private var pushing = false
    /// Mirrors `NativeHeaderModel.dimmed`: the whole bar and the large title
    /// at a fraction of their alpha while a widget is expanded.
    private var dimmed = false
    private weak var boundModel: NativeHeaderModel?

    var inlineTitleAlpha: CGFloat { inlineTitle.alpha }
    var compactHeaderTitle: UIView? { largeTitleEnabled ? inlineTitleHost : nil }

    var pageOffset: CGFloat {
        guard let scroll = webScrollView else { return 0 }
        return scroll.contentOffset.y + scroll.adjustedContentInset.top
    }

    /// Back to `offset` (as `pageOffset` reports it), without animation.
    /// Returns false, and does nothing, while the page is still too short to
    /// hold that offset.
    @discardableResult
    func restorePageOffset(_ offset: CGFloat) -> Bool {
        guard let scroll = webScrollView else { return true }
        let top = -scroll.adjustedContentInset.top
        let maxY = max(top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        let wanted = max(top, offset + top)
        guard wanted <= maxY + 0.5 else { return false }
        if abs(scroll.contentOffset.y - wanted) > 0.5 {
            UIView.performWithoutAnimation {
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: wanted), animated: false)
            }
            mirrorOffset()
            updateTitleTransition()
        }
        return true
    }

    func setPushing(_ pushing: Bool) {
        guard self.pushing != pushing else { return }
        self.pushing = pushing
        if pushing {
            // Out over the slide, from wherever the scroll had left it. The
            // new page starts at its top, where the inline title is hidden,
            // so this is also where the offset would take it.
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                self.inlineTitle.alpha = 0
            }
        } else if let model = boundModel {
            apply(model)
            updateTitleTransition()
        }
    }
    /// The bar is hidden (preview off, or a web overlay is up).
    private var barHidden = false
    /// What the page was last told, so a rotation that changes the bar's
    /// heights tells it again and nothing else does.
    private var lastReportedInsets: (bar: CGFloat, status: CGFloat)?

    /// The band under the compact bar that the large title occupies, and the
    /// distance over which it collapses. The page pads its content by the
    /// compact inset plus this.
    private var largeTitleHeight: CGFloat {
        WebHostingLayout.largeTitleHeight + (headingIsPage ? WebHostingLayout.eyebrowHeight : 0)
    }

    // MARK: - Lifecycle

    deinit {
        displayLink?.invalidate()
    }

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

        buildLargeTitle()
    }

    /// What is on screen right now, as an image. `drawHierarchy` with
    /// `afterScreenUpdates: false` copies the presented frame — which is the
    /// point when this is called from the message that is about to change
    /// the page — but it replaces the whole web view with WebKit's picture,
    /// and the large title lives inside the web view's scroll view, so it is
    /// drawn again on top from its own layers.
    func snapshotImage() -> UIImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return UIGraphicsImageRenderer(bounds: bounds).image { ctx in
            view.drawHierarchy(in: bounds, afterScreenUpdates: false)
            drawLargeTitle(in: ctx.cgContext)
        }
    }

    func renderedSnapshotImage(completion: @escaping (UIImage?) -> Void) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let scroll = webScrollView, let webView = scroll.superview as? WKWebView else {
            completion(snapshotImage())
            return
        }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { completion(nil); return }
            guard let image else { completion(self.snapshotImage()); return }
            let webFrame = webView.convert(webView.bounds, to: self.view)
            completion(UIGraphicsImageRenderer(bounds: bounds).image { ctx in
                // Whatever the web view does not cover (nothing, in practice)
                // keeps the backdrop; then WebKit's picture, then the title.
                (webView.scrollView.backgroundColor ?? webView.backgroundColor)?.setFill()
                ctx.fill(bounds)
                image.draw(in: webFrame)
                self.drawLargeTitle(in: ctx.cgContext)
            })
        }
    }

    /// The large title, drawn from its own layers at its place on screen.
    private func drawLargeTitle(in g: CGContext) {
        guard let scroll = webScrollView, !largeTitleArea.isHidden, largeTitleArea.alpha > 0.01 else { return }
        let frame = scroll.convert(largeTitleArea.frame, to: view)
        g.saveGState()
        g.translateBy(x: frame.origin.x, y: frame.origin.y)
        g.setAlpha(largeTitleArea.alpha)
        largeTitleArea.layer.render(in: g)
        g.restoreGState()
    }

    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        edge == .top && largeTitleEnabled ? proxy : super.contentScrollView(for: edge)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachWebScrollViewIfNeeded()
        // SwiftUI may re-add its content above us on a root-view update;
        // the title must stay on top of the web view.
        if largeTitleArea.superview === view, view.subviews.last !== largeTitleArea {
            largeTitleArea.superview?.bringSubviewToFront(largeTitleArea)
        }
        layoutLargeTitle()
        syncCompactTitle()
        reportInsetsIfChanged()
    }

    private func syncCompactTitle() {
        guard let nav = navigationController, nav.topViewController === self,
              nav.transitionCoordinator == nil else { return }
        (nav.navigationBar as? PassthroughNavigationBar)?.showTitle(compactHeaderTitle)
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

    /// iOS 26 gives every scroll view under a bar a soft edge effect of its
    /// own — the faint gradient at the top of the page. Wanted in portrait,
    /// where it is part of how the bar reads; not in the sidebar layout, where
    /// the bar is two floating buttons and the page should look untouched.
    private func applyEdgeEffects() {
        guard #available(iOS 26.0, *) else { return }
        proxy.topEdgeEffect.isHidden = !largeTitleEnabled
        webScrollView?.topEdgeEffect.isHidden = !largeTitleEnabled
    }

    /// The web view is created by SwiftUI some time after this controller's
    /// view is; hook it the first time layout finds it.
    private func attachWebScrollViewIfNeeded() {
        guard webScrollView == nil, let scroll = Self.findWebScrollView(in: view) else { return }
        webScrollView = scroll
        applyEdgeEffects()
        // The large title lives INSIDE the web view's scroll view, so the
        // compositor moves it with the page. It used to sit over the web
        // view and be translated from a display link that read where the
        // page was drawn — which is always at least a frame behind what is
        // on screen, so the name trailed the content and jittered on every
        // fling, and after a fast scroll to the top it could be left drawn
        // partway down the page until the next sample. As a subview it is
        // simply content: no sampling, no transform, no lag. Only the fade
        // is still driven from the sampled offset, and a frame's lag on an
        // alpha is invisible.
        scroll.addSubview(largeTitleArea)
        layoutLargeTitle()
        // Pull to refresh, UIKit's. Its spinner is nudged down to sit just
        // above the large title (see `layoutLargeTitleNow`): the control's
        // own home is the overscroll gap at the very top of the content, and
        // with no content inset that is under the compact bar.
        refreshControl.addTarget(self, action: #selector(refreshCrossedThreshold), for: .valueChanged)
        scroll.refreshControl = refreshControl
        NativeHeaderModel.shared.refreshDone = { [weak self] in self?.endRefreshing() }
        // Not the scroll view's delegate: that is WebKit's, and taking it is
        // the kind of thing that breaks a pan without saying so. A target on
        // the pan recogniser and KVO on the offset are enough to know when a
        // drag ends and when the deceleration after it stops.
        scroll.panGestureRecognizer.addTarget(self, action: #selector(webPanChanged(_:)))
        let onScroll: () -> Void = { [weak self] in
            guard let self else { return }
            self.mirrorOffset()
            if self.awaitingDecelerationEnd, let scroll = self.webScrollView, !scroll.isDragging, !scroll.isDecelerating {
                self.awaitingDecelerationEnd = false
                self.snapIfNeeded(scroll)
            }
        }
        offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in onScroll(); self?.wake() }
        boundsObservation = scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in onScroll(); self?.wake() }
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        // Never paused while on screen. WebKit scrolls asynchronously: after
        // a fast fling the content keeps moving with the scroll view
        // reporting neither a drag nor a deceleration, so a sampler that
        // stopped on "still" stopped early and the title froze mid-fade
        // (measured: offset 0, alpha 0.6). Idle costs one property read per
        // frame at a low rate; moving, it runs at full rate.
        setSamplingRate(idle: true)
        displayLink = link
        // Above the web view, which SwiftUI has just added on top of us.
        view.bringSubviewToFront(largeTitleArea)
        mirrorOffset()
        #if DEBUG
        runProbeIfRequested()
        #endif
    }

    // MARK: - The two titles

    /// The inline title: the name and a small chevron, opening the title
    /// menu. Faded in as the large one fades out. On a room page it is the
    /// room's name with the home's beneath it as a subtitle, so both stay in
    /// view however far the page has scrolled.
    private lazy var inlineTitle: UIButton = Self.makeInlineTitleButton()

    func compactTitleLookalike(_ title: String) -> UIView {
        let button = Self.makeInlineTitleButton()
        button.configuration?.title = title
        button.configuration?.baseForegroundColor = navigationController?.navigationBar.tintColor ?? .label
        button.alpha = 1
        button.isUserInteractionEnabled = false
        let host = InlineTitleHost(button: button)
        Self.layoutInlineTitle(button, in: host, available: max(80, view.bounds.width - 2 * 120))
        return host
    }

    private static func makeInlineTitleButton() -> UIButton {
        var config = UIButton.Configuration.plain()
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .headline)
            return attributes
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .caption1)
            return attributes
        }
        config.titleAlignment = .center
        config.titlePadding = 0
        // One line each, cut with an ellipsis: a long room name must not
        // wrap and turn the two-line title into three.
        config.titleLineBreakMode = .byTruncatingTail
        config.subtitleLineBreakMode = .byTruncatingTail
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.contentInsets = .zero
        config.baseForegroundColor = .label
        let button = UIButton(configuration: config)
        button.titleLabel?.numberOfLines = 1
        button.subtitleLabel?.numberOfLines = 1
        button.showsMenuAsPrimaryAction = true
        button.alpha = 0
        return button
    }

    /// On a room, group or collection page: the home's name, small, on the
    /// line above the big room name — so the bar itself can stay empty while
    /// the heading is up (one selector at a time) and both names are still
    /// in view. As the heading scrolls under the bar it hands over to
    /// `inlineTitle`, which carries the same pair the other way up.
    private let largeEyebrowLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.isUserInteractionEnabled = false
        return label
    }()

    /// Gives the bar an explicit size for the title and keeps its button
    /// centred as a two-line room title changes to a one-line home title.
    private final class InlineTitleHost: UIView {
        private let button: UIButton

        init(button: UIButton) {
            self.button = button
            super.init(frame: .zero)
            clipsToBounds = false
            addSubview(button)
            setContentCompressionResistancePriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .vertical)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        var preferredSize = CGSize.zero {
            didSet { if preferredSize != oldValue { invalidateIntrinsicContentSize() } }
        }
        override var intrinsicContentSize: CGSize { preferredSize }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The bar owns this host's frame, including while it changes from
            // a two-line room title to the one-line home title during a pop.
            // Centre in the bounds it actually assigned, not the size we
            // requested before the navigation bar has laid out again.
            button.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    private lazy var inlineTitleHost = InlineTitleHost(button: inlineTitle)

    /// Size the host to its title, never wider than the room the bar leaves
    /// between its trailing buttons and their mirror on the left — beyond
    /// that the texts truncate.
    private func layoutInlineTitles() {
        Self.layoutInlineTitle(inlineTitle, in: inlineTitleHost, available: max(80, view.bounds.width - 2 * 120))
        syncCompactTitle()
        navigationController?.navigationBar.setNeedsLayout()
    }

    /// Sizes the button to its text and the host to the button, and says
    /// whether the host's size changed. Shared with the look-alike the
    /// navigator puts in the bar during a pop, so the two are placed alike.
    @discardableResult
    private static func layoutInlineTitle(_ button: UIButton, in host: InlineTitleHost, available: CGFloat) -> Bool {
        // A configuration-based button applies a new title on its next
        // layout pass, so measuring straight after setting one measures the
        // old configuration: "Clitheroe Road" came out 68pt wide and the bar
        // drew a sliver (measured with the probe). Lay it out first.
        button.setNeedsUpdateConfiguration()
        button.setNeedsLayout()
        button.layoutIfNeeded()
        // Whole points with a little slack: the measured sizes are thirds of
        // a point and the bar's container rounds them down, which shaved the
        // last glyph and the chevron's edge (reported as a slight clip).
        let slack: CGFloat = 12
        let buttonSize = button.intrinsicContentSize
        button.bounds = CGRect(x: 0, y: 0, width: min(available, ceil(buttonSize.width) + 4), height: ceil(buttonSize.height) + 2)
        let width = min(available + slack, button.bounds.width + slack)
        let height = button.bounds.height + 2
        let size = CGSize(width: width, height: height)
        let grew = size != host.preferredSize
        host.preferredSize = size
        // Seed an unattached title so the bar can measure it. Once attached,
        // changing its frame here fights the bar's layout: returning from a
        // room briefly moved the home title right and up on each model update.
        if host.superview == nil { host.bounds.size = size }
        host.setNeedsLayout()
        host.layoutIfNeeded()
        return grew
    }

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
    /// The connection dot beside the large title.
    /// The connection dot's button, with a pressed state: a dot that gives
    /// nothing back when touched reads as decoration. While the finger is
    /// down a soft halo fills behind it and the dot shrinks a little; both
    /// spring back on release, whether or not the tap lands.
    private final class StatusDotButton: UIButton {
        override var isHighlighted: Bool {
            didSet {
                guard oldValue != isHighlighted else { return }
                let pressed = isHighlighted
                UIView.animate(withDuration: pressed ? 0.08 : 0.3, delay: 0, usingSpringWithDamping: pressed ? 1 : 0.55, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.viewWithTag(1)?.transform = pressed ? CGAffineTransform(scaleX: 0.78, y: 0.78) : .identity
                    self.viewWithTag(2)?.alpha = pressed ? 1 : 0
                }
            }
        }
    }

    private let largeStatusButton: UIButton = {
        let button = StatusDotButton(type: .custom)
        let halo = UIView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        halo.layer.cornerRadius = 15
        halo.backgroundColor = .tertiarySystemFill
        halo.alpha = 0
        halo.isUserInteractionEnabled = false
        halo.tag = 2
        button.addSubview(halo)
        let dot = UIView(frame: CGRect(x: 9, y: 9, width: 12, height: 12))
        dot.layer.cornerRadius = 6
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.35
        dot.layer.shadowOffset = CGSize(width: 0, height: 1)
        dot.layer.shadowRadius = 1
        dot.isUserInteractionEnabled = false
        dot.tag = 1
        button.addSubview(dot)
        button.accessibilityLabel = "Connection status"
        button.isHidden = true
        return button
    }()

    private func buildLargeTitle() {
        largeTitleArea.clipsToBounds = false
        largeTitleArea.backgroundColor = .clear
        view.addSubview(largeTitleArea)

        largeTitleButton.showsMenuAsPrimaryAction = true
        largeTitleButton.accessibilityLabel = "Switch home"
        largeTitleArea.addSubview(largeTitleButton)
        largeTitleArea.addSubview(largeEyebrowLabel)

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
        // A sibling of the title button so its tap is its own.
        largeTitleArea.addSubview(largeStatusButton)
    }

    /// Lay the large title out for the current text; `updateTitleTransition`
    /// then moves it with the scroll.
    private func layoutLargeTitle() {
        UIView.performWithoutAnimation { layoutLargeTitleNow() }
    }

    private func layoutLargeTitleNow() {
        let inset = compactInset > 0 ? compactInset : view.safeAreaInsets.top
        let height = largeTitleHeight
        // In the scroll view's content space when it has one (content starts
        // at 0: the insets are `.never`), which is the same numbers as in
        // this view's space at offset 0.
        largeTitleArea.frame = CGRect(x: 0, y: inset, width: view.bounds.width, height: height)
        largeTitleArea.isHidden = !largeTitleEnabled || barHidden
        largeTitleArea.superview?.bringSubviewToFront(largeTitleArea)
        // Shifting the control's bounds up draws its spinner that much lower:
        // in the gap that opens between the compact bar and the large title
        // as the page is pulled, which is where UIKit's own large-title bars
        // put it.
        refreshControl.bounds.origin.y = -inset
        refreshControl.isEnabled = largeTitleEnabled && !barHidden

        let leading = max(view.layoutMargins.left, 16)
        let trailingRoom: CGFloat = 60
        let textWidth = ceil((largeTitleLabel.text ?? "").size(withAttributes: [.font: largeTitleLabel.font as Any]).width)
        let maxTextWidth = max(0, view.bounds.width - leading - trailingRoom)
        let width = min(textWidth, maxTextWidth)
        let hasSubtitle = !(largeSubtitleButton.title(for: .normal) ?? "").isEmpty

        // On a page heading the home's name goes first, small, and the big
        // name moves down under it by the band's extra height.
        let eyebrow: CGFloat = headingIsPage ? WebHostingLayout.eyebrowHeight : 0
        largeEyebrowLabel.isHidden = !headingIsPage
        largeEyebrowLabel.frame = CGRect(x: leading, y: 2, width: maxTextWidth, height: eyebrow)
        // 34pt bold sits on a 41pt line, centred in the band. The status line
        // under it does not move the name: it used to lift the name 7pt to
        // make room, and the name jumped every time "Updating…" came and went
        // — which is on every navigation. The line tucks under the name's
        // descenders instead and runs a few points into the gap below the
        // band, which is clear.
        let titleHeight: CGFloat = 41
        let titleY: CGFloat = eyebrow + (WebHostingLayout.largeTitleHeight - titleHeight) / 2
        largeTitleLabel.frame = CGRect(x: leading, y: titleY, width: width, height: titleHeight)
        largeSubtitleButton.frame = CGRect(x: leading, y: titleY + titleHeight - 8, width: maxTextWidth, height: 18)
        largeSubtitleButton.isHidden = !hasSubtitle

        let chevronSize: CGFloat = 22
        largeChevron.frame = CGRect(x: leading + width + 8, y: titleY + (titleHeight - chevronSize) / 2 + 2, width: chevronSize, height: chevronSize)
        largeChevron.layer.cornerRadius = chevronSize / 2
        largeTitleButton.frame = CGRect(x: 0, y: 0, width: leading + width + 8 + chevronSize + 8, height: height)
        let chevronVisible = !largeChevron.isHidden
        let dotX = leading + width + (chevronVisible ? 8 + chevronSize + 6 : 8)
        largeStatusButton.frame = CGRect(x: dotX, y: largeChevron.frame.midY - 15, width: 30, height: 30)

        updateTitleTransition()
    }

    /// Where we are between "large title showing" (0) and "inline title
    /// showing" (1), from the page's offset.
    private var collapseProgress: CGFloat {
        min(1, pageOffsetY / largeTitleHeight)
    }

    /// Fade the large title as it scrolls under the bar; fade the inline
    /// title in over the last part of that travel. (Moving it is the scroll
    /// view's job — the title is one of its subviews.)
    ///
    /// The large name is gone by a little over half the travel — before its
    /// top would pass under the bar's controls — so it fades rather than
    /// being clipped, and the inline name takes over from the halfway point.
    private func updateTitleTransition() {
        // Never animated. These run from the scroll view's own callbacks, and
        // when UIKit makes those inside one of its animation blocks the
        // writes inherit it: the title then eased towards a stale target for
        // as long as UIKit's curve lasted — faded late at the top, or drawn
        // hundreds of points down the page while every value here read
        // correctly (measured with the probe).
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            // Position is the scroll view's business now (see
            // `attachWebScrollViewIfNeeded`); until it is found the title sits
            // in this view at offset 0 and there is nothing to translate.
            if !largeTitleEnabled {
                // Compact row only: the inline title is the title.
                inlineTitle.alpha = 1
                return
            }
            // The large title dissolves as it goes under the bar and the
            // inline one takes over from the halfway point. On a room page
            // the bar is empty until then — the heading carries both names,
            // home small above room — and the inline title then carries the
            // same pair the other way up.
            let progress = collapseProgress
            let dim: CGFloat = dimmed ? WebHostingLayout.dimmedAlpha : 1
            largeTitleArea.alpha = max(0, 1 - progress / 0.55) * dim
            if !pushing { inlineTitle.alpha = max(0, (progress - 0.5) / 0.5) }
        }
    }

    // MARK: - Scrolling

    /// Set when a drag ended with momentum; the snap waits for it to stop.
    private var awaitingDecelerationEnd = false

    // MARK: Pull to refresh
    //
    // The page's own pull is off under the bar — the document scrolls, not
    // its inner container — so UIKit's control on the web view's scroll view
    // takes over. It arms when the pull crosses UIKit's threshold and acts
    // when the finger lifts, because the depth of the pull decides what it
    // means: an ordinary refresh, or past `hardPull` the page's hard-reload
    // countdown, which is what a very long pull meant on the web control.
    private let refreshControl = UIRefreshControl()
    private var refreshArmed = false
    private var deepestPull: CGFloat = 0
    private var refreshStarted: Date?


    /// The page's offset as drawn this frame. During WebKit's own momentum
    /// scrolling the on-screen position runs ahead of `contentOffset`, which
    /// only catches up as the fling settles — so a title driven from the
    /// model lagged the content by up to a second (reported, and a
    /// programmatic scroll never showed it). The presentation layer has the
    /// value the user is looking at.
    private var pageOffsetY: CGFloat {
        guard let scroll = webScrollView else { return 0 }
        let drawn = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
        return max(0, drawn)
    }

    #if DEBUG
    /// Temporary probe: everything that could make the title invisible.
    ///   launch with -com.homecast.devProbe YES; read com.homecast.devProbeLog
    func runProbeIfRequested() {
        guard UserDefaults.standard.bool(forKey: "com.homecast.devProbe"), let scroll = webScrollView else { return }
        var log: [String] = []
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = String(format: "%.1f", Date().timeIntervalSince(start))
            let area = self.largeTitleArea
            let idx = self.view.subviews.firstIndex(of: area) ?? -1
            let pres = area.layer.presentation()
            let bpres = self.largeTitleButton.layer.presentation()
            log.append("\(t) off=\(scroll.contentOffset.y) pageY=\(self.pageOffsetY) alpha=\(area.alpha) presOp=\(pres?.opacity ?? -1) hidden=\(area.isHidden) presHidden=\(pres?.isHidden ?? false) frame=\(area.frame) presPos=\(pres?.position ?? .zero) btnTy=\(self.largeTitleButton.transform.ty) btnPres=\(bpres?.affineTransform().ty ?? -999) btnHidden=\(self.largeTitleButton.isHidden) lblHidden=\(self.largeTitleLabel.isHidden) lblAlpha=\(self.largeTitleLabel.alpha) text=\(self.largeTitleLabel.text ?? "") z=\(idx)/\(self.view.subviews.count) enabled=\(self.largeTitleEnabled) barHidden=\(self.barHidden) heading=\(self.headingIsPage) covered=\(NativeHeaderModel.shared.covered) win=\(area.window != nil)")
            let pan = scroll.panGestureRecognizer
            let probeMid = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.height * 0.7)
            let hitMid = self.view.hitTest(probeMid, with: nil)
            let hitWin = self.view.window?.hitTest(self.view.convert(probeMid, to: nil), with: nil)
            let webView = scroll.superview
            func describe(_ v: UIView?) -> String {
                guard let v else { return "nil" }
                var chain: [String] = []
                var cur: UIView? = v
                while let c = cur, chain.count < 12 { chain.append("\(type(of: c))\(c.frame.integral.size == v.window?.bounds.size ? "*" : "")"); cur = c.superview }
                return "\(type(of: v)) frame=\(v.frame) alpha=\(v.alpha) bg=\(v.backgroundColor.map { String(describing: $0) } ?? "nil") ui=\(v.isUserInteractionEnabled) subs=\(v.subviews.count) grs=\(v.gestureRecognizers?.map { String(describing: type(of: $0)) } ?? []) chain=\(chain.joined(separator: " < "))"
            }
            log.append("   HIT mid: \(describe(hitWin))")
            let tv = self.compactHeaderTitle
            log.append("   TITLE host=\(self.inlineTitleHost.frame) bounds=\(self.inlineTitleHost.bounds) pref=\(self.inlineTitleHost.preferredSize) win=\(self.inlineTitleHost.superview.map { $0.convert(self.inlineTitleHost.frame, to: nil) } ?? .zero) super=\(tv?.superview.map { String(describing: type(of: $0)) } ?? "nil") superFrame=\(tv?.superview?.frame ?? .zero) isHost=\(tv === self.inlineTitleHost) btn=\(self.inlineTitle.frame) btnAlpha=\(self.inlineTitle.alpha) lbl=\(self.inlineTitle.titleLabel?.frame ?? .zero) lblText=\(self.inlineTitle.titleLabel?.text ?? "") sub=\(self.inlineTitle.subtitleLabel?.frame ?? .zero) eyebrow=\(self.largeEyebrowLabel.frame) eyebrowHidden=\(self.largeEyebrowLabel.isHidden) viewW=\(self.view.bounds.width) constraints=\(self.inlineTitleHost.constraints.count) tam=\(self.inlineTitleHost.translatesAutoresizingMaskIntoConstraints)")
            log.append("   TREE self.view: \(self.view.subviews.map { "\(type(of: $0))\($0.frame)" }) nav: \(self.navigationController?.view.subviews.map { "\(type(of: $0))\($0.frame)" } ?? [])")
            if let w = webView { log.append("   WEB subs: \(w.subviews.map { "\(type(of: $0))\($0.frame) ui=\($0.isUserInteractionEnabled)" }) scrollSubs: \(scroll.subviews.map { "\(type(of: $0))\($0.frame)" })") }
            log.append("   UIKIT view=\(self.view.bounds) web=\(webView?.frame ?? .zero) webHidden=\(webView?.isHidden ?? true) webUI=\(webView?.isUserInteractionEnabled ?? false) scrollBounds=\(scroll.bounds) content=\(scroll.contentSize) inset=\(scroll.adjustedContentInset) scrollEnabled=\(scroll.isScrollEnabled) scrollUI=\(scroll.isUserInteractionEnabled) panEnabled=\(pan.isEnabled) panState=\(pan.state.rawValue) dragging=\(scroll.isDragging) proxy=\(self.proxy.frame) proxyUI=\(self.proxy.isUserInteractionEnabled) hitMid=\(type(of: hitMid as AnyObject)) hitWin=\(type(of: hitWin as AnyObject)) grs=\(self.view.gestureRecognizers?.count ?? 0) navGrs=\(self.navigationController?.view.gestureRecognizers?.map { String(describing: type(of: $0)) } ?? [])")
            if (Int(t.replacingOccurrences(of: ".", with: "")) ?? 0) % 10 == 0, let web = webView as? WKWebView {
                web.evaluateJavaScript("JSON.stringify({sh: document.scrollingElement.scrollHeight, st: document.scrollingElement.scrollTop, ih: innerHeight, iw: innerWidth, inset: getComputedStyle(document.documentElement).getPropertyValue('--native-header-inset'), sat: getComputedStyle(document.documentElement).getPropertyValue('--safe-area-top'), bodyH: document.body.scrollHeight, bodyOv: getComputedStyle(document.body).overflowY, htmlOv: getComputedStyle(document.documentElement).overflowY, enabled: window.homecastNativeHeaderEnabled, avail: window.homecastNativeHeaderAvailable, bridge: !!window.__homecastNativeHeader, entry: [...document.scripts].map(s => s.src).filter(s => /index-/.test(s)).join(','), fixedShell: !!document.querySelector('main')?.closest('.fixed.inset-0'), chain: (() => { const out=[]; for (let n=document.querySelector('main'); n && n!==document.documentElement; n=n.parentElement) out.push(n.tagName+'.'+(n.className||'').toString().slice(0,50)); return out; })(), mobileApp: window.isHomecastMobileApp ?? window.isHomecastIOSApp ?? null, ua: navigator.userAgent.slice(-60), ta: getComputedStyle(document.body).touchAction, sw: !!navigator.serviceWorker?.controller})") { result, error in
                    log.append("   JS \(t) \(result.map { String(describing: $0) } ?? "nil") err=\(error.map { String(describing: $0) } ?? "-")")
                }
            }
            if log.count > 400 { log.removeFirst(log.count - 400) }
            UserDefaults.standard.set(log.joined(separator: "\n"), forKey: "com.homecast.devProbeLog")
        }
    }
    #endif

    private var samplingIdle = true

    private func setSamplingRate(idle: Bool) {
        samplingIdle = idle
        displayLink?.preferredFrameRateRange = idle
            ? CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)
            : CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    }

    /// Something is moving: sample at full rate.
    private func wake() {
        stillFrames = 0
        if samplingIdle { setSamplingRate(idle: false) }
    }

    @objc private func sample() {
        guard let scroll = webScrollView else { return }
        let y = pageOffsetY
        if y != lastSampledOffset {
            lastSampledOffset = y
            stillFrames = 0
            if samplingIdle { setSamplingRate(idle: false) }
            mirrorOffset()
            if awaitingDecelerationEnd, !scroll.isDragging, !scroll.isDecelerating {
                awaitingDecelerationEnd = false
                snapIfNeeded(scroll)
            }
        } else if !scroll.isDragging, !scroll.isDecelerating {
            stillFrames += 1
            // A couple of seconds still: drop to the idle rate, keep looking.
            if stillFrames > 240, !samplingIdle { setSamplingRate(idle: true) }
        }
    }

    @objc private func refreshCrossedThreshold() {
        // Fires as the pull crosses the threshold, finger still down. Decide
        // on release, when the depth is known — unless it arrived after.
        if webScrollView?.isDragging == true {
            refreshArmed = true
        } else {
            fireRefresh()
        }
    }

    private func fireRefresh() {
        refreshArmed = false
        refreshStarted = Date()
        NativeHeaderModel.shared.refresh(deepestPull < -WebHostingLayout.hardPull ? "hard" : "soft")
        deepestPull = 0
    }

    /// Stop the spinner, but not before it has been seen: a refresh the page
    /// answers instantly would otherwise flick.
    private func endRefreshing() {
        let shown = refreshStarted.map { Date().timeIntervalSince($0) } ?? 1
        refreshStarted = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 0.6 - shown)) { [weak self] in
            self?.refreshControl.endRefreshing()
        }
    }

    @objc private func webPanChanged(_ pan: UIPanGestureRecognizer) {
        wake()
        if pan.state == .began { deepestPull = 0 }
        if pan.state == .changed, let scroll = webScrollView { deepestPull = min(deepestPull, scroll.contentOffset.y) }
        if (pan.state == .ended || pan.state == .cancelled), refreshArmed { fireRefresh() }
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
        let pageY = pageOffsetY
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
        boundModel = model
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
        let ink: UIColor? = style == .dark ? .white : style == .light ? .black : nil
        // A newly selected home can report its appearance before its wallpaper
        // is ready. Keep the bar's existing ink until the slide has finished.
        if !pushing {
            navigationController?.overrideUserInterfaceStyle = style
            navigationController?.navigationBar.tintColor = ink
            moreItem.tintColor = ink
            searchItem.tintColor = ink
        }
        refreshControl.tintColor = ink
        inlineTitle.configuration?.baseForegroundColor = ink ?? .label
        largeEyebrowLabel.textColor = ink?.withAlphaComponent(0.75) ?? .secondaryLabel
        largeTitleLabel.textColor = ink ?? .label
        // The chevron takes the title's ink, on a faint disc of the same —
        // white over a dark page, not the system's grey.
        largeChevron.tintColor = ink ?? .label
        largeChevron.backgroundColor = (ink ?? .label).withAlphaComponent(0.18)

        if dimmed != model.dimmed {
            dimmed = model.dimmed
            let alpha: CGFloat = dimmed ? WebHostingLayout.dimmedAlpha : 1
            UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.navigationController?.navigationBar.alpha = alpha
            }
            updateTitleTransition()
        }
        if largeTitleEnabled != model.largeTitle {
            largeTitleEnabled = model.largeTitle
            largeTitleArea.isHidden = !largeTitleEnabled || barHidden
            // In the sidebar layout the sidebar already names and switches
            // homes, so the bar carries no title at all — just its buttons,
            // floating: no scroll-edge band, and taps beside them fall through.
            syncCompactTitle()
            setContentScrollView(largeTitleEnabled ? proxy : nil, for: .top)
            applyEdgeEffects()
            if let bar = navigationController?.navigationBar as? PassthroughNavigationBar {
                bar.passesThrough = !largeTitleEnabled
                // With no scroll view to track, UIKit falls back to the bar's
                // standard, blurred background — a band across the top of a
                // layout that wants none. Transparent in the sidebar layout;
                // the system defaults, and the scroll-edge effect, in portrait.
                if largeTitleEnabled {
                    bar.standardAppearance = UINavigationBarAppearance()
                    bar.scrollEdgeAppearance = nil
                    bar.compactAppearance = nil
                } else {
                    let clear = UINavigationBarAppearance()
                    clear.configureWithTransparentBackground()
                    bar.standardAppearance = clear
                    bar.scrollEdgeAppearance = clear
                    bar.compactAppearance = clear
                }
            }
            lastReportedInsets = nil
        }
        let title = model.title.isEmpty ? "Homecast" : model.title
        let heading = model.heading.trimmingCharacters(in: .whitespaces)
        headingIsPage = !heading.isEmpty && heading != title
        // The compact bar: home name; or on a room page the room with the
        // home beneath it, once the heading has scrolled away. The heading
        // shows the home small above the big room name until then.
        if !pushing {
            inlineTitle.configuration?.title = headingIsPage ? heading : title
            inlineTitle.configuration?.subtitle = headingIsPage ? title : nil
        }
        largeEyebrowLabel.text = title
        largeTitleLabel.text = headingIsPage ? heading : title
        largeSubtitleButton.setTitle(model.subtitle, for: .normal)

        // The title menu is the one selector: the homes as a row, then this
        // home's rooms and groups and the collections, with the current one
        // ticked. Only one of it is ever on screen: the big title while it is
        // up, the bar's once that has scrolled away (on a room page the bar
        // is empty until then; the heading carries both names).
        let menu = Self.buildTitleMenu(model)
        largeTitleButton.menu = menu
        largeChevron.isHidden = menu == nil
        if !pushing {
            inlineTitle.menu = menu
            inlineTitle.configuration?.image = menu == nil ? nil : UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        }

        // No leading button, like the Home app: navigation is the title menu.
        navigationItem.leftBarButtonItem = nil

        // The same two items every time, with their menu and action updated
        // in place: a fresh UIBarButtonItem on every model change is a
        // replacement to the bar, and on iOS 26 a replaced glass item fades
        // out and back in — which showed as the search and ⋯ buttons
        // blinking whenever the stack changed under them.
        var trailing: [UIBarButtonItem] = []
        if model.showOverflow {
            if let menu = Self.buildMenu(model) {
                // The page's ⋯ menu, drawn by UIKit. Tapping the item opens the
                // menu directly; an item calls back into the page by id.
                moreItem.menu = menu
                moreItem.primaryAction = nil
            } else {
                moreItem.menu = nil
                moreItem.primaryAction = UIAction(image: UIImage(systemName: "ellipsis")) { _ in model.tap(.overflow) }
            }
            moreItem.image = UIImage(systemName: "ellipsis")
            trailing.append(moreItem)
        }
        if model.showSearch {
            searchItem.primaryAction = UIAction(image: UIImage(systemName: "magnifyingglass")) { _ in model.tap(.search) }
            trailing.append(searchItem)
        }
        if navigationItem.rightBarButtonItems ?? [] != trailing {
            navigationItem.rightBarButtonItems = trailing
        }

        // The connection dot sits beside the large title, after the chevron
        // — the same spot the web heading puts its own. Tapping opens the
        // page's connection popover.
        largeStatusButton.isHidden = model.statusColor == nil
        largeStatusButton.viewWithTag(1)?.backgroundColor = model.statusColor
        largeStatusButton.removeTarget(nil, action: nil, for: .allEvents)
        largeStatusButton.addAction(UIAction { _ in model.tap(.status) }, for: .touchUpInside)

        if !pushing { layoutInlineTitles() }
        layoutLargeTitle()
        // Now, not on the next layout pass: after a rotation back to
        // portrait there may not be one, and the page kept the landscape
        // padding under a large title that had come back (measured).
        reportInsetsIfChanged()
    }

    /// A menu row's symbol, drawn light. UIKit's default for a menu image is
    /// the regular weight, which next to 17pt text reads heavy — the house
    /// in particular. The current home keeps its filled house.
    private static func menuImage(_ symbol: String?) -> UIImage? {
        guard let symbol else { return nil }
        return UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .light))
    }

    private static func buildTitleMenu(_ model: NativeHeaderModel) -> UIMenu? {
        guard !model.homes.isEmpty || !model.navigation.isEmpty else { return nil }
        var children: [UIMenuElement] = []
        // Which home, first and as a row of buttons — one tap, nothing to
        // scroll past. Only when there is more than one to choose from.
        let current = model.currentHomeId
        if model.homes.count > 1 {
            let homes: [UIMenuElement] = model.homes.map { home in
                UIAction(title: home.name, image: Self.menuImage(home.id == current ? "house.fill" : "house"), state: home.id == current ? .on : .off) { [weak model] _ in
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
            let image = Self.menuImage(item.symbol)
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
                let image = Self.menuImage(item.symbol)
                return UIAction(title: item.label, image: image, attributes: attributes) { [weak model] _ in
                    model?.menuAction(item.id)
                }
            }
            return UIMenu(title: section.title ?? "", options: .displayInline, children: actions)
        }
        return UIMenu(children: sections)
    }

    private lazy var moreItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: nil)
        item.accessibilityLabel = "More"
        return item
    }()

    private lazy var searchItem: UIBarButtonItem = {
        let item = UIBarButtonItem(primaryAction: UIAction(image: UIImage(systemName: "magnifyingglass")) { _ in })
        item.accessibilityLabel = "Search"
        return item
    }()
}

#endif
