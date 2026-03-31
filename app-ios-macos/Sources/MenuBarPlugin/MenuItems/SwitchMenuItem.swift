//
//  SwitchMenuItem.swift
//  Homecast
//
//  Menu item view for switches and outlets
//

import AppKit

/// Menu item view for switches and outlets
/// Layout: [Icon] [Name] [State] [Toggle]
/// Height: 28px (DS.ControlSize.menuItemHeight)
final class SwitchMenuItem: HighlightingMenuItemView {
    // MARK: - Properties

    private var powerState: Bool = false

    // MARK: - UI Components

    private let toggle = ToggleSwitch()

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
        addSubview(toggle)

        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))

        layoutSubviews()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        if layoutUnreachable() { return }
        super.layoutSubviews()

        let height = frame.height
        let iconSize = DS.ControlSize.iconMedium
        let switchWidth = DS.ControlSize.switchWidth
        let switchHeight = DS.ControlSize.switchHeight

        // Icon on left
        let iconY = (height - iconSize) / 2
        iconView.frame = NSRect(x: DS.Spacing.menuItemPadding, y: iconY, width: iconSize, height: iconSize)

        // Toggle on right
        let switchX = frame.width - DS.Spacing.menuItemPadding - switchWidth
        let switchY = (height - switchHeight) / 2
        toggle.frame = NSRect(x: switchX, y: switchY, width: switchWidth, height: switchHeight)

        // Name label fills remaining space
        let labelX = DS.Spacing.md + iconSize + DS.Spacing.sm
        let labelWidth = switchX - labelX - DS.Spacing.sm
        nameLabel.frame = NSRect(x: labelX, y: (height - 17) / 2, width: max(0, labelWidth), height: 17)

        // Hide state label for compact switch items
        stateLabel.isHidden = true
    }

    // MARK: - Configuration

    override func configure(with config: MenuItemConfiguration) {
        super.configure(with: config)

        powerState = config.powerState ?? false
        toggle.setOn(powerState, animated: false)
        toggle.isEnabled = isReachable

        if isReachable {
            updateIconTint()
        }
    }

    // MARK: - State Updates

    override func updateCharacteristic(_ type: String, value: Any) {
        let typeLower = type.lowercased()

        if typeLower == "powerstate" || typeLower == "on" {
            if let boolValue = value as? Bool {
                powerState = boolValue
            } else if let intValue = value as? Int {
                powerState = intValue != 0
            }

            toggle.setOn(powerState, animated: true)
            updateIconTint()
        }
    }

    override func updateReachableAppearance() {
        super.updateReachableAppearance()
        toggle.isEnabled = isReachable
        toggle.isHidden = !isReachable

        if isReachable {
            updateIconTint()
        }
        needsLayout = true
    }

    // MARK: - Private

    private func updateIconTint() {
        let iconName = PhosphorIcon.defaultIconName(for: configuration?.iconCategory ?? "switch")
        if powerState {
            iconView.image = PhosphorIcon.fill(iconName)
            iconView.contentTintColor = DS.Colors.switchOn
        } else {
            iconView.image = PhosphorIcon.regular(iconName)
            iconView.contentTintColor = DS.Colors.iconForeground
        }
    }

    @objc private func toggleChanged(_ sender: ToggleSwitch) {
        powerState = sender.isOn
        updateIconTint()

        let charType = configuration?.powerCharType ?? "PowerState"
        setCharacteristic(type: charType, value: powerState)
    }
}
