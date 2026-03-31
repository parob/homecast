//
//  SensorMenuItem.swift
//  Homecast
//
//  Menu item view for read-only sensors
//

import AppKit

/// Menu item view for read-only sensors
/// Layout: [Icon] [Name] [Value with unit]
/// Height: 28px (DS.ControlSize.menuItemHeight)
final class SensorMenuItem: HighlightingMenuItemView {
    // MARK: - Properties

    private var sensorValue: Any?
    private var sensorUnit: String?
    private var sensorType: SensorType = .generic

    enum SensorType {
        case temperature
        case humidity
        case motion
        case contact
        case occupancy
        case lightLevel
        case carbonDioxide
        case carbonMonoxide
        case airQuality
        case camera
        case doorbell
        case bridge
        case remote
        case smokeAlarm
        case doorWindow
        case generic
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

        // Value on right (wider for sensor values)
        let valueLabelWidth: CGFloat = 60
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

        sensorValue = config.sensorValue
        sensorUnit = config.sensorUnit
        sensorType = determineSensorType(from: config.iconCategory)

        // Populate sensorValue from type-specific accessory fields when generic sensorValue is nil
        if sensorValue == nil, let accessory = config.accessory {
            switch sensorType {
            case .contact, .doorWindow:
                sensorValue = accessory["contactState"]
            case .motion:
                sensorValue = accessory["motionDetected"]
            case .occupancy:
                sensorValue = accessory["occupancyDetected"]
            case .temperature:
                sensorValue = accessory["currentTemperature"]
            default:
                break
            }
        }

        if isReachable {
            updateValueDisplay()
        }
        updateIcon()
    }

    // MARK: - State Updates

    override func updateCharacteristic(_ type: String, value: Any) {
        let typeLower = type.lowercased()

        // Handle various sensor characteristic types
        if typeLower.contains("temperature") ||
           typeLower.contains("humidity") ||
           typeLower.contains("lightlevel") ||
           typeLower.contains("co2") ||
           typeLower.contains("pm") ||
           typeLower.contains("motion") ||
           typeLower.contains("contact") ||
           typeLower.contains("occupancy") ||
           typeLower.contains("smoke") {
            sensorValue = value
            updateValueDisplay()
        }
    }

    // MARK: - Private

    private func determineSensorType(from category: String) -> SensorType {
        let cat = category.lowercased()

        if cat.contains("temperature") {
            return .temperature
        } else if cat.contains("humidity") {
            return .humidity
        } else if cat.contains("motion") {
            return .motion
        } else if cat.contains("contact") {
            return .contact
        } else if cat.contains("occupancy") {
            return .occupancy
        } else if cat.contains("light") && cat.contains("sensor") {
            return .lightLevel
        } else if cat.contains("carbon") && cat.contains("dioxide") {
            return .carbonDioxide
        } else if cat.contains("carbon") && cat.contains("monoxide") {
            return .carbonMonoxide
        } else if cat.contains("air") && cat.contains("quality") {
            return .airQuality
        } else if cat == "camera" || cat.contains("camera") || cat.contains("video") {
            return .camera
        } else if cat == "doorbell" || cat.contains("doorbell") {
            return .doorbell
        } else if cat == "info" || cat.contains("bridge") {
            return .bridge
        } else if cat == "remote" || cat == "button" || cat.contains("programmable") {
            return .remote
        } else if cat == "smoke_alarm" || cat.contains("smoke") {
            return .smokeAlarm
        } else if cat == "door_window" {
            return .doorWindow
        }
        return .generic
    }

    private func updateValueDisplay() {
        // Informational device types always show their label (no sensor value expected)
        switch sensorType {
        case .camera:
            stateLabel.stringValue = "Camera"
            stateLabel.textColor = DS.Colors.mutedForeground
            return
        case .doorbell:
            stateLabel.stringValue = "Doorbell"
            stateLabel.textColor = DS.Colors.mutedForeground
            return
        case .bridge:
            stateLabel.stringValue = "Bridge"
            stateLabel.textColor = DS.Colors.mutedForeground
            return
        case .remote:
            stateLabel.stringValue = "Remote"
            stateLabel.textColor = DS.Colors.mutedForeground
            return
        default:
            break
        }

        guard let value = sensorValue else {
            stateLabel.stringValue = "—"
            stateLabel.textColor = DS.Colors.mutedForeground
            return
        }

        var displayValue = ""
        var color: NSColor = DS.Colors.mutedForeground

        switch sensorType {
        case .temperature:
            if let temp = value as? Double {
                displayValue = String(format: "%.1f°", temp)
                color = temp > 25 ? DS.Colors.thermostatHeat : DS.Colors.thermostatCool
            } else if let temp = value as? Int {
                displayValue = "\(temp)°"
                color = temp > 25 ? DS.Colors.thermostatHeat : DS.Colors.thermostatCool
            }

        case .humidity:
            if let humidity = value as? Double {
                displayValue = String(format: "%.0f%%", humidity)
            } else if let humidity = value as? Int {
                displayValue = "\(humidity)%"
            }
            color = DS.Colors.info

        case .motion, .occupancy:
            if let detected = value as? Bool {
                displayValue = detected ? "Detected" : "Clear"
                color = detected ? DS.Colors.warning : DS.Colors.mutedForeground
            } else if let detected = value as? Int {
                let isDetected = detected != 0
                displayValue = isDetected ? "Detected" : "Clear"
                color = isDetected ? DS.Colors.warning : DS.Colors.mutedForeground
            }

        case .contact:
            if let open = value as? Bool {
                displayValue = open ? "Open" : "Closed"
                color = open ? DS.Colors.warning : DS.Colors.success
            } else if let open = value as? Int {
                let isOpen = open != 0
                displayValue = isOpen ? "Open" : "Closed"
                color = isOpen ? DS.Colors.warning : DS.Colors.success
            }

        case .lightLevel:
            if let level = value as? Double {
                displayValue = String(format: "%.0f lux", level)
            } else if let level = value as? Int {
                displayValue = "\(level) lux"
            }
            color = DS.Colors.mutedForeground

        case .carbonDioxide:
            if let ppm = value as? Double {
                displayValue = String(format: "%.0f ppm", ppm)
                color = ppm > 1000 ? DS.Colors.warning : DS.Colors.mutedForeground
            } else if let ppm = value as? Int {
                displayValue = "\(ppm) ppm"
                color = ppm > 1000 ? DS.Colors.warning : DS.Colors.mutedForeground
            }

        case .carbonMonoxide:
            if let detected = value as? Bool {
                displayValue = detected ? "Alert" : "OK"
                color = detected ? DS.Colors.destructive : DS.Colors.mutedForeground
            } else if let level = value as? Int {
                displayValue = level > 0 ? "Alert" : "OK"
                color = level > 0 ? DS.Colors.destructive : DS.Colors.mutedForeground
            }

        case .airQuality:
            if let quality = value as? Int {
                let qualityLabels = ["Excellent", "Good", "Fair", "Poor", "Bad"]
                displayValue = quality < qualityLabels.count ? qualityLabels[quality] : "Unknown"
                color = quality > 2 ? DS.Colors.warning : DS.Colors.mutedForeground
            }

        case .camera, .doorbell, .bridge, .remote:
            break // Handled by early return above

        case .smokeAlarm:
            if let detected = value as? Bool {
                displayValue = detected ? "Alert" : "OK"
                color = detected ? DS.Colors.destructive : DS.Colors.success
            } else if let level = value as? Int {
                displayValue = level > 0 ? "Alert" : "OK"
                color = level > 0 ? DS.Colors.destructive : DS.Colors.success
            }

        case .doorWindow:
            if let open = value as? Bool {
                displayValue = open ? "Open" : "Closed"
                color = open ? DS.Colors.warning : DS.Colors.success
            } else if let open = value as? Int {
                let isOpen = open != 0
                displayValue = isOpen ? "Open" : "Closed"
                color = isOpen ? DS.Colors.warning : DS.Colors.success
            }

        case .generic:
            displayValue = "\(value)"
            if let unit = sensorUnit {
                displayValue += " \(unit)"
            }
        }

        stateLabel.stringValue = displayValue
        stateLabel.textColor = color
    }

    private func updateIcon() {
        let iconName: String

        switch sensorType {
        case .temperature:
            iconName = "thermometer"
        case .humidity:
            iconName = "drop-half"
        case .motion:
            iconName = "person-simple-walk"
        case .contact, .doorWindow:
            iconName = "door-open"
        case .occupancy:
            iconName = "user"
        case .lightLevel:
            iconName = "sun"
        case .carbonDioxide:
            iconName = "cloud"
        case .carbonMonoxide, .smokeAlarm:
            iconName = "warning"
        case .airQuality:
            iconName = "wind"
        case .camera:
            iconName = "video-camera"
        case .doorbell:
            iconName = "bell"
        case .bridge:
            iconName = "broadcast"
        case .remote:
            iconName = "game-controller"
        case .generic:
            iconName = "question"
        }

        if let icon = PhosphorIcon.regular(iconName) {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "sensor.fill", accessibilityDescription: nil)
        }
        iconView.contentTintColor = DS.Colors.iconForeground
    }
}
