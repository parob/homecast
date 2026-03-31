//
//  HighlightingMenuItemView.swift
//  Homecast
//
//  Base class for all device menu item views with hover highlighting
//

import AppKit

class HighlightingMenuItemView: NSView {
    // MARK: - Properties

    /// Controller for handling device control actions
    weak var controller: MenuBarController?

    /// Current configuration
    var configuration: MenuItemConfiguration?

    /// The home ID for this menu item
    var homeId: String = ""

    /// Whether the device is reachable
    var isReachable: Bool = true {
        didSet {
            if isReachable != oldValue {
                updateReachableAppearance()
            }
        }
    }

    /// Callback for action (click)
    var onAction: (() -> Void)?
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?
    var closesMenuOnAction: Bool = true

    // MARK: - Private Properties

    private var trackingArea: NSTrackingArea?
    private var isMouseInside = false
    private var originalTextColors: [ObjectIdentifier: NSColor] = [:]
    private var originalTintColors: [ObjectIdentifier: NSColor] = [:]

    // MARK: - UI Components (for subclasses)

    let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()

    let nameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = DS.Typography.label
        label.textColor = DS.Colors.foreground
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    let stateLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = DS.Typography.labelSmall
        label.textColor = DS.Colors.mutedForeground
        label.alignment = .right
        return label
    }()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupBaseViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupBaseViews()
    }

    // MARK: - Setup

    private func setupBaseViews() {
        wantsLayer = true

        // Add common subviews
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(stateLabel)

        // Default layout for icon, name, state
        let iconSize = DS.ControlSize.iconMedium
        let iconY = (frame.height - iconSize) / 2

        iconView.frame = NSRect(x: DS.Spacing.menuItemPadding, y: iconY, width: iconSize, height: iconSize)
        nameLabel.frame = NSRect(x: DS.Spacing.menuItemPadding + iconSize + DS.Spacing.sm, y: (frame.height - 17) / 2, width: 120, height: 17)
        stateLabel.frame = NSRect(x: frame.width - DS.Spacing.menuItemPadding - 60, y: (frame.height - 14) / 2, width: 40, height: 14)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutSubviews()
    }

    /// Override in subclasses to customize layout
    func layoutSubviews() {
        let iconSize = DS.ControlSize.iconMedium
        iconView.frame = NSRect(x: DS.Spacing.menuItemPadding, y: (frame.height - iconSize) / 2, width: iconSize, height: iconSize)
    }

    // MARK: - Window Management

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Reset highlight state when menu closes (window becomes nil)
        // or when menu reopens (window changes)
        if isMouseInside {
            isMouseInside = false
            updateTextColors(highlighted: false)
            needsDisplay = true
        }
    }

    // MARK: - Configuration

    /// Configure the view with accessory or group data
    func configure(with config: MenuItemConfiguration) {
        self.configuration = config
        self.homeId = config.homeId
        self.isReachable = config.isReachable

        nameLabel.stringValue = config.displayName

        // Set icon using Phosphor if available, fallback to SF Symbol
        let iconName = config.isGroup
            ? PhosphorIcon.defaultGroupIcon
            : PhosphorIcon.defaultIconName(for: config.iconCategory)

        if let phosphorIcon = PhosphorIcon.regular(iconName) {
            iconView.image = phosphorIcon
        } else {
            // Fallback to SF Symbol
            iconView.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        }
        iconView.contentTintColor = DS.Colors.iconForeground

        updateReachableAppearance()
    }

    // MARK: - Appearance

    /// Update appearance based on reachability
    func updateReachableAppearance() {
        let tintColor: NSColor = isReachable ? DS.Colors.iconForeground : DS.Colors.mutedForeground
        let textColor: NSColor = isReachable ? DS.Colors.foreground : DS.Colors.mutedForeground

        iconView.contentTintColor = tintColor
        nameLabel.textColor = textColor

        if !isReachable {
            stateLabel.stringValue = "Unreachable"
            stateLabel.textColor = DS.Colors.mutedForeground
            stateLabel.isHidden = false
        }
    }

    /// Layout helper for unreachable state: shows only icon, name, and "Unreachable" label.
    /// Returns true if unreachable layout was applied (caller should return early from layoutSubviews).
    func layoutUnreachable() -> Bool {
        guard !isReachable else { return false }

        let height = frame.height
        let iconSize = DS.ControlSize.iconMedium

        iconView.frame = NSRect(x: DS.Spacing.menuItemPadding, y: (height - iconSize) / 2, width: iconSize, height: iconSize)

        let stateWidth: CGFloat = 70
        let stateX = frame.width - DS.Spacing.menuItemPadding - stateWidth
        stateLabel.frame = NSRect(x: stateX, y: (height - 14) / 2, width: stateWidth, height: 14)
        stateLabel.isHidden = false

        let labelX = DS.Spacing.menuItemPadding + iconSize + DS.Spacing.sm
        nameLabel.frame = NSRect(x: labelX, y: (height - 17) / 2, width: max(0, stateX - labelX - DS.Spacing.xs), height: 17)

        return true
    }

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        updateTextColors(highlighted: true)
        needsDisplay = true
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        updateTextColors(highlighted: false)
        needsDisplay = true
        onMouseExit?()
    }

    private func updateTextColors(highlighted: Bool) {
        updateSubviewColors(in: self, highlighted: highlighted)
    }

    private func updateSubviewColors(in view: NSView, highlighted: Bool) {
        for subview in view.subviews {
            // Skip controls that manage their own appearance
            if subview is ToggleSwitch || subview is ModernSlider {
                continue
            }

            if let modeButton = subview as? ModeButton {
                modeButton.isMenuHighlighted = highlighted
            } else if let textField = subview as? NSTextField {
                let key = ObjectIdentifier(textField)
                if highlighted {
                    if originalTextColors[key] == nil {
                        originalTextColors[key] = textField.textColor
                    }
                    textField.textColor = .selectedMenuItemTextColor
                } else if let original = originalTextColors[key] {
                    textField.textColor = original
                }
            } else if let imageView = subview as? NSImageView {
                let key = ObjectIdentifier(imageView)
                if highlighted {
                    if originalTintColors[key] == nil {
                        originalTintColors[key] = imageView.contentTintColor
                    }
                    imageView.contentTintColor = .selectedMenuItemTextColor
                } else if let original = originalTintColors[key] {
                    imageView.contentTintColor = original
                }
            } else if let button = subview as? NSButton {
                let key = ObjectIdentifier(button)
                if highlighted {
                    if originalTintColors[key] == nil {
                        originalTintColors[key] = button.contentTintColor
                    }
                    button.contentTintColor = .selectedMenuItemTextColor
                } else if let original = originalTintColors[key] {
                    button.contentTintColor = original
                }
            }

            // Recurse into child views
            if !(subview is NSControl) || subview is ModeButton {
                updateSubviewColors(in: subview, highlighted: highlighted)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isReachable, let action = onAction else { return }
        if closesMenuOnAction {
            isMouseInside = false
            updateTextColors(highlighted: false)
            needsDisplay = true
            enclosingMenuItem?.menu?.cancelTracking()
            action()
        } else {
            // Restore original colors, perform action, then re-save post-action colors
            updateTextColors(highlighted: false)
            action()
            originalTextColors.removeAll()
            originalTintColors.removeAll()
            updateTextColors(highlighted: true)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isMouseInside {
            let rect = bounds.insetBy(dx: 5, dy: 2)
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: rect, xRadius: DS.Radius.md, yRadius: DS.Radius.md).fill()
        }
    }

    // MARK: - Subclass Helpers

    /// Set characteristic on the accessory
    func setCharacteristic(type: String, value: Any) {
        guard let id = configuration?.id else { return }

        if configuration?.isGroup == true {
            controller?.setServiceGroupCharacteristic(groupId: id, homeId: homeId, type: type, value: value)
        } else {
            controller?.setCharacteristic(accessoryId: id, type: type, value: value)
        }
    }

    // MARK: - CharacteristicUpdatable

    var accessoryId: String? {
        configuration?.isGroup == true ? nil : configuration?.id
    }

    var serviceGroupId: String? {
        configuration?.isGroup == true ? configuration?.id : nil
    }

    /// Override in subclasses to handle specific characteristics
    func updateCharacteristic(_ type: String, value: Any) {
        // Base implementation does nothing
    }

    func updateReachability(_ newReachable: Bool) {
        isReachable = newReachable
    }
}

// MARK: - CharacteristicUpdatable Conformance

extension HighlightingMenuItemView: CharacteristicUpdatable {}
