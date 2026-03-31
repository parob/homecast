//
//  SmokeAlarmMenuItem.swift
//  Homecast
//
//  Menu item view for smoke alarm / CO detector devices (e.g. Nest Protect)
//

import AppKit

/// Menu item view for smoke alarm and CO detector accessories
/// Layout: [Icon] [Name] [Status + Battery]
/// Height: 28px (DS.ControlSize.menuItemHeight)
final class SmokeAlarmMenuItem: HighlightingMenuItemView {
    // MARK: - Properties

    private var smokeDetected: Bool = false
    private var coDetected: Bool = false
    private var batteryLevel: Int?
    private var statusLowBattery: Bool = false

    /// Whether alarm is active (smoke or CO detected)
    private var isAlarming: Bool {
        smokeDetected || coDetected
    }

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

        // Status on right (wider to fit battery info)
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

        smokeDetected = config.smokeDetected ?? false
        coDetected = config.coDetected ?? false
        batteryLevel = config.batteryLevel
        statusLowBattery = config.statusLowBattery ?? false

        if isReachable {
            updateStatusDisplay()
        }
        updateIcon()
    }

    // MARK: - State Updates

    override func updateCharacteristic(_ type: String, value: Any) {
        let typeLower = type.lowercased()

        if typeLower.contains("smoke") {
            if let boolVal = value as? Bool {
                smokeDetected = boolVal
            } else if let intVal = value as? Int {
                smokeDetected = intVal != 0
            }
            updateStatusDisplay()
            updateIcon()
        }

        if typeLower.contains("carbon") && typeLower.contains("monoxide") {
            if let boolVal = value as? Bool {
                coDetected = boolVal
            } else if let intVal = value as? Int {
                coDetected = intVal != 0
            }
            updateStatusDisplay()
            updateIcon()
        }

        if typeLower.contains("battery") && typeLower.contains("level") {
            if let intVal = value as? Int {
                batteryLevel = intVal
            } else if let doubleVal = value as? Double {
                batteryLevel = Int(doubleVal)
            }
            updateStatusDisplay()
        }

        if typeLower.contains("lowbattery") || (typeLower.contains("low") && typeLower.contains("battery")) {
            if let boolVal = value as? Bool {
                statusLowBattery = boolVal
            } else if let intVal = value as? Int {
                statusLowBattery = intVal != 0
            }
            updateStatusDisplay()
        }
    }

    // MARK: - Private

    private func updateStatusDisplay() {
        var status: String
        var color: NSColor

        if smokeDetected && coDetected {
            status = "ALARM"
            color = DS.Colors.destructive
        } else if smokeDetected {
            status = "SMOKE"
            color = DS.Colors.destructive
        } else if coDetected {
            status = "CO"
            color = DS.Colors.destructive
        } else {
            status = "OK"
            color = DS.Colors.success
        }

        // Append battery info
        if statusLowBattery {
            status += " · Low"
            if !isAlarming { color = DS.Colors.warning }
        } else if let level = batteryLevel {
            status += " · \(level)%"
        }

        stateLabel.stringValue = status
        stateLabel.textColor = color
    }

    private func updateIcon() {
        let isFilled = isAlarming
        if let icon = PhosphorIcon.icon("shield-check", filled: isFilled) {
            iconView.image = icon
        }
        iconView.contentTintColor = isAlarming ? DS.Colors.destructive : DS.Colors.success
    }
}
