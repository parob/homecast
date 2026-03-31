//
//  BlindMenuItem.swift
//  Homecast
//
//  Menu item view for window coverings/blinds
//

import AppKit

/// Menu item view for window coverings/blinds
/// Layout: [Icon] [Name] [Slider] [▲/▼ Button]
/// Height: 28px (DS.ControlSize.menuItemHeight)
final class BlindMenuItem: HighlightingMenuItemView {
    // MARK: - Properties

    private var position: Int = 0

    // MARK: - UI Components

    private let slider = ModernSlider()

    private let actionButton: NSButton = {
        let button = NSButton()
        button.bezelStyle = .inline
        button.setButtonType(.momentaryPushIn)
        button.title = ""
        button.imagePosition = .imageOnly
        button.isBordered = false
        return button
    }()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: DS.ControlSize.menuItemWidth, height: DS.ControlSize.menuItemHeight))
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    // MARK: - Setup

    private func setupViews() {
        addSubview(slider)
        addSubview(actionButton)

        // Setup slider with blind-specific color
        slider.progressTintColor = DS.Colors.sliderBlind
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = false

        // Setup action button
        actionButton.target = self
        actionButton.action = #selector(handleButtonPress)

        // Click row to toggle open/close
        closesMenuOnAction = false
        onAction = { [weak self] in
            guard let self = self else { return }
            let newPosition = self.position > 0 ? 0 : 100
            self.position = newPosition
            self.slider.doubleValue = Double(newPosition)
            self.updateIconForPosition()
            self.updateButton()
            self.setCharacteristic(type: "TargetPosition", value: newPosition)
        }

        layoutSubviews()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        if layoutUnreachable() { return }
        super.layoutSubviews()

        let height = frame.height
        let iconSize = DS.ControlSize.iconMedium
        let sliderWidth = DS.ControlSize.sliderWidth
        let buttonSize = iconSize

        // Icon on left
        let iconY = (height - iconSize) / 2
        iconView.frame = NSRect(x: DS.Spacing.menuItemPadding, y: iconY, width: iconSize, height: iconSize)

        // Action button on right
        let buttonX = frame.width - DS.Spacing.menuItemPadding - buttonSize
        let buttonY = (height - buttonSize) / 2
        actionButton.frame = NSRect(x: buttonX, y: buttonY, width: buttonSize, height: buttonSize)

        // Slider before button
        let sliderX = buttonX - sliderWidth - DS.Spacing.sm
        let sliderY = (height - 12) / 2
        slider.frame = NSRect(x: sliderX, y: sliderY, width: sliderWidth, height: 12)

        // Name label fills remaining space
        let labelX = DS.Spacing.menuItemPadding + iconSize + DS.Spacing.sm
        let labelWidth = sliderX - labelX - DS.Spacing.sm
        nameLabel.frame = NSRect(x: labelX, y: (height - 17) / 2, width: max(0, labelWidth), height: 17)

        // Hide state label - slider and button communicate state
        stateLabel.isHidden = true
    }

    // MARK: - Configuration

    override func configure(with config: MenuItemConfiguration) {
        super.configure(with: config)

        position = config.position ?? 0

        guard isReachable else { return }

        slider.doubleValue = Double(position)
        slider.isEnabled = true
        actionButton.isEnabled = true

        updateIconForPosition()
        updateButton()
    }

    // MARK: - State Updates

    override func updateCharacteristic(_ type: String, value: Any) {
        let typeLower = type.lowercased()

        if typeLower == "currentposition" || typeLower == "current_position" {
            if let intValue = value as? Int {
                position = intValue
            } else if let doubleValue = value as? Double {
                position = Int(doubleValue)
            }

            slider.doubleValue = Double(position)
            updateIconForPosition()
            updateButton()
        }
    }

    override func updateReachableAppearance() {
        super.updateReachableAppearance()

        slider.isEnabled = isReachable
        slider.isHidden = !isReachable
        actionButton.isEnabled = isReachable
        actionButton.isHidden = !isReachable

        if isReachable {
            updateIconForPosition()
            updateButton()
        }
        needsLayout = true
    }

    // MARK: - Private

    private func updateIconForPosition() {
        // Update icon based on position using Phosphor
        let iconName = PhosphorIcon.defaultIconName(for: "window_covering")
        if position > 50 {
            iconView.image = PhosphorIcon.fill(iconName)
            iconView.contentTintColor = DS.Colors.sliderBlind
        } else if position > 0 {
            iconView.image = PhosphorIcon.regular(iconName)
            iconView.contentTintColor = DS.Colors.sliderBlind
        } else {
            iconView.image = PhosphorIcon.regular(iconName)
            iconView.contentTintColor = DS.Colors.iconForeground
        }
    }

    private func updateButton() {
        let iconName: String
        let tintColor: NSColor

        if position > 0 {
            // Open or partial - show close (down) button
            iconName = "caret-down"
            tintColor = DS.Colors.sliderBlind
        } else {
            // Closed - show open (up) button
            iconName = "caret-up"
            tintColor = DS.Colors.mutedForeground
        }

        if let icon = PhosphorIcon.fill(iconName) {
            actionButton.image = icon
        }
        actionButton.contentTintColor = tintColor
    }

    @objc private func sliderChanged(_ sender: ModernSlider) {
        let value = Int(sender.doubleValue)
        position = value
        updateIconForPosition()
        updateButton()
        setCharacteristic(type: "TargetPosition", value: value)
    }

    @objc private func handleButtonPress() {
        let newPosition = position > 0 ? 0 : 100
        position = newPosition
        slider.doubleValue = Double(newPosition)
        updateIconForPosition()
        updateButton()
        setCharacteristic(type: "TargetPosition", value: newPosition)
    }
}
