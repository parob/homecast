//
//  RemoteMenuItem.swift
//  Homecast
//
//  Menu item view for remote / button devices (e.g. Hue Dimmer Remote)
//

import AppKit

/// Menu item view for remote and button accessories
/// Layout: [Icon] [Name] [Info + Battery]
/// Height: 28px (DS.ControlSize.menuItemHeight)
final class RemoteMenuItem: HighlightingMenuItemView {
    // MARK: - Properties

    private var buttonCount: Int = 0
    private var batteryLevel: Int?
    private var statusLowBattery: Bool = false

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
        stateLabel.font = DS.Typography.labelSmall
        layoutSubviews()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let height = frame.height
        let iconSize = DS.ControlSize.iconMedium

        // Icon on left
        let iconY = (height - iconSize) / 2
        iconView.frame = NSRect(x: DS.Spacing.menuItemPadding, y: iconY, width: iconSize, height: iconSize)

        // Info on right (wider to fit battery info)
        let valueLabelWidth: CGFloat = 80
        let valueLabelX = frame.width - DS.Spacing.menuItemPadding - valueLabelWidth
        stateLabel.frame = NSRect(x: valueLabelX, y: (height - 14) / 2, width: valueLabelWidth, height: 14)

        // Name label fills remaining space
        let labelX = DS.Spacing.menuItemPadding + iconSize + DS.Spacing.sm
        let labelWidth = valueLabelX - labelX - DS.Spacing.xs
        nameLabel.frame = NSRect(x: labelX, y: (height - 17) / 2, width: max(0, labelWidth), height: 17)
    }

    // MARK: - Configuration

    override func configure(with config: MenuItemConfiguration) {
        super.configure(with: config)

        buttonCount = config.buttonCount ?? 0
        batteryLevel = config.batteryLevel
        statusLowBattery = config.statusLowBattery ?? false

        if isReachable {
            updateInfoDisplay()
        }
        updateIcon()
    }

    // MARK: - State Updates

    override func updateCharacteristic(_ type: String, value: Any) {
        let typeLower = type.lowercased()

        if typeLower.contains("battery") && typeLower.contains("level") {
            if let intVal = value as? Int {
                batteryLevel = intVal
            } else if let doubleVal = value as? Double {
                batteryLevel = Int(doubleVal)
            }
            updateInfoDisplay()
        }

        if typeLower.contains("lowbattery") || (typeLower.contains("low") && typeLower.contains("battery")) {
            if let boolVal = value as? Bool {
                statusLowBattery = boolVal
            } else if let intVal = value as? Int {
                statusLowBattery = intVal != 0
            }
            updateInfoDisplay()
        }
    }

    // MARK: - Private

    private func updateInfoDisplay() {
        // Button count label (matching web app's RemoteWidget/ButtonWidget)
        var info: String
        if buttonCount == 4 {
            info = "Dimmer"
        } else if buttonCount == 1 {
            info = "Button"
        } else if buttonCount > 0 {
            info = "\(buttonCount) buttons"
        } else {
            info = "Remote"
        }

        // Append battery info
        if statusLowBattery {
            info += " · Low"
            stateLabel.textColor = DS.Colors.warning
        } else if let level = batteryLevel {
            info += " · \(level)%"
            stateLabel.textColor = DS.Colors.mutedForeground
        } else {
            stateLabel.textColor = DS.Colors.mutedForeground
        }

        stateLabel.stringValue = info
    }

    private func updateIcon() {
        if let icon = PhosphorIcon.regular("remote-control") {
            iconView.image = icon
        }
        iconView.contentTintColor = DS.Colors.iconForeground
    }
}
