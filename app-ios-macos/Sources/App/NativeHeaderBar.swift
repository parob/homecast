import UIKit

#if os(iOS) && !targetEnvironment(macCatalyst)

/// The top chrome, drawn natively — a **preview**, off by default.
///
/// Asked for on parob/homecast-cloud#120: "iOS only is fine, we want native so
/// let's preview it, don't worry about tab bar". So this is the header row and
/// nothing else — no tab bar, no Mac, no Android. `MobileTabBar` stays web,
/// deliberately: it is a pinned-items bar with eight pin types, three tap
/// behaviours, drag-to-reorder and popovers that open above it, and `UITabBar`
/// offers a fixed item set with a selected index. That is not the same object.
///
/// ## This bar is native pixels driving web behaviour, and that is the whole risk
///
/// Every one of the four controls opens **web** UI — the left drawer, the
/// status popover, the search overlay, the ⋮ menu. None of them has a native
/// counterpart and none is going to get one here. So the native button's only
/// job is to call back into the page, and the page's only job is to tell this
/// bar what to draw. Two crossings, both narrow, both in this file:
///
/// | direction | carries |
/// |---|---|
/// | page → native | `apply(_:)` — title, the status dot's colour, which controls exist |
/// | native → page | `onTap` — which of the four was pressed |
///
/// Nothing else crosses. In particular this bar never learns what a *home* is,
/// never reads HomeKit, and cannot navigate: it is a renderer for a state the
/// page owns. That is what keeps it cheap to delete if the preview is rejected.
///
/// ## Why a `UIVisualEffectView` rather than more CSS
///
/// The web header already emulates this — `backdrop-filter: blur(24px)
/// saturate(180%)` behind `.material-thin` — and emulating it is the thing the
/// report was complaining about. A real `UIBlurEffect` samples what is actually
/// behind the view, tracks the system's light/dark and accessibility settings
/// for free, and is the one part of "feels native" that genuinely cannot be
/// done in the web layer. If this preview is worth keeping, that is why.
final class NativeHeaderBar: UIView {

    /// The four controls, named as the page names them.
    ///
    /// Raw values are the wire format — they cross into JavaScript verbatim as
    /// `window.__homecastNativeHeader.tap('<rawValue>')`, so renaming a case is
    /// a protocol change and breaks an installed build talking to a newer page.
    enum Control: String {
        case menu
        case status
        case search
        case overflow
    }

    /// What the page publishes down for this bar to draw.
    struct State {
        var title: String = ""
        /// The connection dot's fill. `nil` hides the dot entirely — which is
        /// what a page with no home selected wants, not a grey circle.
        var statusColor: UIColor?
        var showMenu: Bool = true
        var showSearch: Bool = true
        var showOverflow: Bool = true
    }

    /// Fired when one of the four is pressed. The owner turns it into a call
    /// into the page; this view deliberately knows nothing about how.
    var onTap: ((Control) -> Void)?

    /// The control row's height, below whatever safe-area inset is in force.
    ///
    /// 52pt rather than `UINavigationBar`'s 44: the row it replaces is 80px of
    /// CSS pixels with 40px touch targets inside it, and dropping to 44 moved
    /// the content up far enough to read as a different screen rather than the
    /// same screen drawn better.
    static let rowHeight: CGFloat = 52

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let row = UIView()
    private let titleLabel = UILabel()
    private let menuButton = UIButton(type: .system)
    private let searchButton = UIButton(type: .system)
    private let overflowButton = UIButton(type: .system)
    private let statusButton = UIButton(type: .system)
    private let statusDot = UIView()
    private let rightStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    // MARK: - Construction

    private func setUp() {
        translatesAutoresizingMaskIntoConstraints = false
        // The blur supplies the surface; the view itself must not paint one or
        // it sits as an opaque slab in front of the effect.
        backgroundColor = .clear

        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        configure(menuButton, symbol: "line.3.horizontal", label: "Menu", control: .menu)
        configure(searchButton, symbol: "magnifyingglass", label: "Search", control: .search)
        configure(overflowButton, symbol: "ellipsis", label: "More", control: .overflow)

        // The status control is a tinted dot rather than a glyph, so it gets a
        // bare button with the dot centred inside it — the button keeps the
        // 44pt target Apple asks for while the dot stays 10pt.
        statusButton.translatesAutoresizingMaskIntoConstraints = false
        statusButton.accessibilityLabel = "Connection status"
        statusButton.addTarget(self, action: #selector(statusTapped), for: .touchUpInside)
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.layer.cornerRadius = 5
        statusDot.isUserInteractionEnabled = false
        statusButton.addSubview(statusDot)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        // The title yields before the controls do. A long home name should
        // ellipsise; it should never push ⋮ off the trailing edge.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.lineBreakMode = .byTruncatingTail

        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.axis = .horizontal
        rightStack.alignment = .center
        rightStack.spacing = 2
        rightStack.addArrangedSubview(statusButton)
        rightStack.addArrangedSubview(searchButton)
        rightStack.addArrangedSubview(overflowButton)

        row.addSubview(menuButton)
        row.addSubview(titleLabel)
        row.addSubview(rightStack)

        NSLayoutConstraint.activate([
            // The blur runs to the very top so it covers the status bar too —
            // stopping at the safe area would leave a hard edge exactly where
            // the system draws the clock.
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            // The row sits below the inset; the bar's own height then follows
            // from the row rather than being a number anyone has to maintain.
            row.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight),

            menuButton.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            menuButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: menuButton.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -8),

            rightStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            statusButton.widthAnchor.constraint(equalToConstant: 32),
            statusButton.heightAnchor.constraint(equalToConstant: 44),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
            statusDot.centerXAnchor.constraint(equalTo: statusButton.centerXAnchor),
            statusDot.centerYAnchor.constraint(equalTo: statusButton.centerYAnchor),
        ])
    }

    private func configure(_ button: UIButton, symbol: String, label: String, control: Control) {
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addTarget(self, action: #selector(controlTapped(_:)), for: .touchUpInside)
        button.tag = Self.tag(for: control)
    }

    // MARK: - Taps
    //
    // `tag` is an Int, so the enum has to survive a round trip through one.
    // Kept as two small functions rather than an `Int` raw value on the enum so
    // that the raw value can stay the string the page sends.

    private static func tag(for control: Control) -> Int {
        switch control {
        case .menu: return 1
        case .status: return 2
        case .search: return 3
        case .overflow: return 4
        }
    }

    private static func control(for tag: Int) -> Control? {
        switch tag {
        case 1: return .menu
        case 2: return .status
        case 3: return .search
        case 4: return .overflow
        default: return nil
        }
    }

    @objc private func controlTapped(_ sender: UIButton) {
        guard let control = Self.control(for: sender.tag) else { return }
        onTap?(control)
    }

    @objc private func statusTapped() {
        onTap?(.status)
    }

    // MARK: - State from the page

    /// What is on screen now. Merged into, never replaced — see `merge(_:)`.
    private var state = State()

    /// Merge a partial state from the page and redraw.
    ///
    /// **A publish is a partial update, and that is load-bearing.** The two
    /// things this bar draws are owned by two different React components — the
    /// title by `AppHeader`, the connection colour by `StatusBadge` — and
    /// neither knows the other's state. If a publish replaced rather than
    /// merged, a title change would blank the dot and a reconnect would blank
    /// the title, several times a second during a pod handoff.
    ///
    /// So an absent key means *unchanged*, which is also what makes this safe
    /// against a page older or newer than this build: an unknown key is ignored
    /// and a missing one changes nothing.
    ///
    /// `statusColor` is the one field where absent and `null` differ — absent
    /// leaves the dot alone, `null` hides it.
    func merge(_ payload: [String: Any]) {
        if let title = payload["title"] as? String { state.title = title }
        if let show = payload["showMenu"] as? Bool { state.showMenu = show }
        if let show = payload["showSearch"] as? Bool { state.showSearch = show }
        if let show = payload["showOverflow"] as? Bool { state.showOverflow = show }

        if payload.index(forKey: "statusColor") != nil {
            // Present. Either a hex string, or JSON `null` — which arrives as
            // `NSNull`, not as a missing key, and means hide the dot.
            if let hex = payload["statusColor"] as? String {
                state.statusColor = UIColor(hex: hex)
            } else {
                state.statusColor = nil
            }
        }

        redraw()
    }

    private func redraw() {
        titleLabel.text = state.title
        menuButton.isHidden = !state.showMenu
        searchButton.isHidden = !state.showSearch
        overflowButton.isHidden = !state.showOverflow

        if let color = state.statusColor {
            statusDot.backgroundColor = color
            statusButton.isHidden = false
        } else {
            statusButton.isHidden = true
        }
    }
}

// MARK: - Colour from the page

extension UIColor {

    /// `#rgb`, `#rrggbb` or `#rrggbbaa`, with or without the hash.
    ///
    /// The page owns the status palette and will go on changing it, so the
    /// colour crosses as a string rather than as a named case here — a new
    /// state on the web side must not need a new build to render.
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }

        if text.count == 3 {
            // #rgb → #rrggbb, so the short form the CSS uses works unchanged.
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6 || text.count == 8,
              let value = UInt64(text, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        if text.count == 6 {
            r = CGFloat((value & 0xFF0000) >> 16) / 255
            g = CGFloat((value & 0x00FF00) >> 8) / 255
            b = CGFloat(value & 0x0000FF) / 255
            a = 1
        } else {
            r = CGFloat((value & 0xFF000000) >> 24) / 255
            g = CGFloat((value & 0x00FF0000) >> 16) / 255
            b = CGFloat((value & 0x0000FF00) >> 8) / 255
            a = CGFloat(value & 0x000000FF) / 255
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

#endif
