//
//  SubmenuItemView.swift
//  Homecast
//
//  Custom menu item view for items with submenus (rooms, home selector, etc.)
//  Provides consistent spacing and a custom chevron indicator
//

import AppKit

/// Custom view for menu items that have submenus
/// Layout: [Icon] [Name] [Chevron]
///
/// Uses `enclosingMenuItem?.isHighlighted` instead of custom tracking areas
/// so that highlighting stays in sync with AppKit's menu tracking (which includes
/// "triangle zone" logic for diagonal movement toward open submenus).
final class SubmenuItemView: NSView {
    // MARK: - Properties

    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()

    private let nameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = DS.Typography.label
        label.textColor = DS.Colors.foreground
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let chevronView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        if let chevron = PhosphorIcon.regular("caret-right") {
            view.image = chevron
        }
        view.contentTintColor = DS.Colors.mutedForeground
        return view
    }()

    private var lastHighlightState = false

    // MARK: - Initialization

    init(title: String, icon: NSImage?) {
        super.init(frame: NSRect(x: 0, y: 0, width: DS.ControlSize.menuItemWidth, height: DS.ControlSize.menuItemHeight))

        nameLabel.stringValue = title
        iconView.image = icon
        iconView.contentTintColor = DS.Colors.iconForeground

        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(chevronView)

        layoutSubviews()
    }

    private func layoutSubviews() {
        let height = frame.height
        let iconSize = DS.ControlSize.iconMedium
        let chevronSize: CGFloat = 10

        // Icon on left
        let iconY = (height - iconSize) / 2
        iconView.frame = NSRect(x: DS.Spacing.md, y: iconY, width: iconSize, height: iconSize)

        // Chevron on right
        let chevronX = frame.width - DS.Spacing.md - chevronSize
        let chevronY = (height - chevronSize) / 2
        chevronView.frame = NSRect(x: chevronX, y: chevronY, width: chevronSize, height: chevronSize)

        // Name label fills remaining space
        let labelX = DS.Spacing.md + iconSize + DS.Spacing.sm
        let labelWidth = chevronX - labelX - DS.Spacing.xs
        nameLabel.frame = NSRect(x: labelX, y: (height - 17) / 2, width: max(0, labelWidth), height: 17)
    }

    // MARK: - Window Management

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if lastHighlightState {
            lastHighlightState = false
            updateColors(highlighted: false)
        }
    }

    // MARK: - Colors

    private func updateColors(highlighted: Bool) {
        if highlighted {
            nameLabel.textColor = .selectedMenuItemTextColor
            iconView.contentTintColor = .selectedMenuItemTextColor
            chevronView.contentTintColor = .selectedMenuItemTextColor
        } else {
            nameLabel.textColor = DS.Colors.foreground
            iconView.contentTintColor = DS.Colors.iconForeground
            chevronView.contentTintColor = DS.Colors.mutedForeground
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Use AppKit's tracking state as the single source of truth for highlighting.
        // This respects the "triangle zone" that AppKit maintains when a submenu is open,
        // preventing highlight flicker when the mouse crosses other items en route to a submenu.
        let highlighted = enclosingMenuItem?.isHighlighted ?? false

        if highlighted != lastHighlightState {
            lastHighlightState = highlighted
            updateColors(highlighted: highlighted)
        }

        if highlighted {
            let rect = bounds.insetBy(dx: 5, dy: 2)
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: rect, xRadius: DS.Radius.md, yRadius: DS.Radius.md).fill()
        }
    }
}
