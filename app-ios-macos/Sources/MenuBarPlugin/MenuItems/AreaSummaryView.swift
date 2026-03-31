//
//  AreaSummaryView.swift
//  Homecast
//
//  Aggregated sensor summary view for menu bar submenus
//  Shows temperature, humidity, motion, lock, and contact status at a glance
//

import AppKit

// MARK: - Data Structures

struct SensorReading {
    let accessoryName: String
    let roomName: String?
    let value: Double // numeric value or enum (e.g. lock state 0/1/2, boolean as 0/1)
}

struct AreaSummaryData {
    var temperatures: [Double] = []
    var humidities: [Double] = []
    var motionActiveCount: Int = 0
    var motionTotalCount: Int = 0
    var lockedCount: Int = 0
    var unlockedCount: Int = 0
    var jammedCount: Int = 0
    var openContactCount: Int = 0
    var closedContactCount: Int = 0
    var lowBatteryCount: Int = 0

    // Per-accessory readings for tooltip detail
    var temperatureReadings: [SensorReading] = []
    var humidityReadings: [SensorReading] = []
    var motionReadings: [SensorReading] = []
    var lockReadings: [SensorReading] = []
    var contactReadings: [SensorReading] = []
    var lowBatteryReadings: [SensorReading] = []

    var hasData: Bool {
        !temperatures.isEmpty ||
        !humidities.isEmpty ||
        motionTotalCount > 0 ||
        (lockedCount + unlockedCount + jammedCount) > 0 ||
        (openContactCount + closedContactCount) > 0 ||
        lowBatteryCount > 0
    }

    var avgTemperature: Double? {
        guard !temperatures.isEmpty else { return nil }
        return temperatures.reduce(0, +) / Double(temperatures.count)
    }

    var minTemperature: Double? { temperatures.min() }
    var maxTemperature: Double? { temperatures.max() }

    var avgHumidity: Double? {
        guard !humidities.isEmpty else { return nil }
        return humidities.reduce(0, +) / Double(humidities.count)
    }

    var minHumidity: Double? { humidities.min() }
    var maxHumidity: Double? { humidities.max() }

    var totalLocks: Int { lockedCount + unlockedCount + jammedCount }
    var totalContacts: Int { openContactCount + closedContactCount }
}

// MARK: - Tooltip Formatting

private func formatReadingsTooltip(
    title: String,
    readings: [SensorReading],
    formatValue: (Double) -> String
) -> String {
    guard !readings.isEmpty else { return title }

    var lines = [title]

    // Group by room
    var roomGroups: [(String, [SensorReading])] = []
    var roomOrder: [String] = []
    var roomMap: [String: [SensorReading]] = [:]

    for reading in readings {
        let key = reading.roomName ?? "Unknown"
        if roomMap[key] == nil {
            roomOrder.append(key)
        }
        roomMap[key, default: []].append(reading)
    }
    for key in roomOrder {
        if let group = roomMap[key] {
            roomGroups.append((key, group))
        }
    }

    let hasMultipleRooms = roomGroups.count > 1

    if hasMultipleRooms {
        for (roomName, roomReadings) in roomGroups {
            lines.append("")
            lines.append(roomName)
            for reading in roomReadings {
                lines.append("  \(reading.accessoryName) \u{2014} \(formatValue(reading.value))")
            }
        }
    } else {
        for reading in readings {
            lines.append("  \(reading.accessoryName) \u{2014} \(formatValue(reading.value))")
        }
    }

    return lines.joined(separator: "\n")
}

// MARK: - Summary View

final class AreaSummaryView: NSView {
    // MARK: - Properties

    private let itemSpacing: CGFloat = DS.Spacing.sm
    private let rowSpacing: CGFloat = 4
    private let rowHeight: CGFloat = 18
    private var summaryItems: [SummaryItemView] = []

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: DS.ControlSize.menuItemWidth, height: rowHeight))
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
        wantsLayer = true
    }

    // MARK: - Flow Layout

    override func layout() {
        super.layout()
        layoutItems()
    }

    private func layoutItems() {
        let padding = DS.Spacing.menuItemPadding
        let maxWidth = bounds.width - padding * 2
        var x: CGFloat = padding
        var y: CGFloat = 3 // top padding
        var currentRowHeight: CGFloat = 0

        for item in summaryItems {
            let itemSize = item.intrinsicContentSize
            // Wrap to next row if this item doesn't fit (unless it's the first on the row)
            if x > padding && (x - padding + itemSize.width) > maxWidth {
                y += currentRowHeight + rowSpacing
                x = padding
                currentRowHeight = 0
            }
            item.frame = NSRect(x: x, y: y, width: itemSize.width, height: itemSize.height)
            x += itemSize.width + itemSpacing
            currentRowHeight = max(currentRowHeight, itemSize.height)
        }

        // Update own height to fit all rows
        let totalHeight = y + currentRowHeight + 3 // bottom padding
        if abs(frame.height - totalHeight) > 0.5 {
            frame.size.height = totalHeight
        }
    }

    override var intrinsicContentSize: NSSize {
        let padding = DS.Spacing.menuItemPadding
        let maxWidth = DS.ControlSize.menuItemWidth - padding * 2
        var x: CGFloat = 0
        var rows: CGFloat = 1
        var currentRowHeight: CGFloat = 0

        for item in summaryItems {
            let itemSize = item.intrinsicContentSize
            if x > 0 && (x + itemSize.width) > maxWidth {
                rows += 1
                x = 0
                currentRowHeight = 0
            }
            x += itemSize.width + itemSpacing
            currentRowHeight = max(currentRowHeight, itemSize.height)
        }

        let totalHeight = rows * rowHeight + (rows - 1) * rowSpacing + 6 // 3pt top + 3pt bottom padding
        return NSSize(width: DS.ControlSize.menuItemWidth, height: totalHeight)
    }

    // MARK: - Configuration

    func configure(with data: AreaSummaryData) {
        // Clear existing items
        for item in summaryItems {
            item.removeFromSuperview()
        }
        summaryItems.removeAll()

        // Temperature
        if let avg = data.avgTemperature {
            let label: String
            if data.temperatures.count == 1 {
                label = String(format: "%.1f\u{00B0}", avg)
            } else if let min = data.minTemperature, let max = data.maxTemperature, abs(max - min) >= 0.5 {
                label = String(format: "%.0f-%.0f\u{00B0}", min, max)
            } else {
                label = String(format: "%.1f\u{00B0}", avg)
            }
            let tooltip = formatReadingsTooltip(
                title: String(format: "Temperature: %.1f\u{00B0} (avg)", avg),
                readings: data.temperatureReadings,
                formatValue: { String(format: "%.1f\u{00B0}", $0) }
            )
            let item = SummaryItemView(icon: "thermometer", label: label, color: DS.Colors.mutedForeground, bgColor: DS.Colors.muted, tooltipText: tooltip)
            summaryItems.append(item)
            addSubview(item)
        }

        // Humidity
        if let avg = data.avgHumidity {
            let label: String
            if data.humidities.count == 1 {
                label = String(format: "%.0f%%", avg)
            } else if let min = data.minHumidity, let max = data.maxHumidity, abs(max - min) >= 3 {
                label = String(format: "%.0f-%.0f%%", min, max)
            } else {
                label = String(format: "%.0f%%", avg)
            }
            let tooltip = formatReadingsTooltip(
                title: String(format: "Humidity: %.0f%% (avg)", avg),
                readings: data.humidityReadings,
                formatValue: { String(format: "%.0f%%", $0) }
            )
            let item = SummaryItemView(icon: "drop-half", label: label, color: DS.Colors.mutedForeground, bgColor: DS.Colors.muted, tooltipText: tooltip)
            summaryItems.append(item)
            addSubview(item)
        }

        // Motion
        if data.motionTotalCount > 0 {
            let hasMotion = data.motionActiveCount > 0
            let label = hasMotion ? "\(data.motionActiveCount) active" : "Clear"
            let color = hasMotion ? DS.Colors.warningForeground : DS.Colors.mutedForeground
            let bgColor = hasMotion ? DS.Colors.warningBackground : DS.Colors.muted
            let tooltip = formatReadingsTooltip(
                title: "Motion: \(data.motionActiveCount)/\(data.motionTotalCount) active",
                readings: data.motionReadings,
                formatValue: { $0 > 0 ? "Motion detected" : "No motion" }
            )
            let item = SummaryItemView(icon: "person-simple-walk", label: label, color: color, bgColor: bgColor, tooltipText: tooltip)
            summaryItems.append(item)
            addSubview(item)
        }

        // Locks
        if data.totalLocks > 0 {
            let label: String
            let icon: String
            let color: NSColor
            let bgColor: NSColor

            if data.jammedCount > 0 {
                label = "\(data.jammedCount) jammed"
                icon = "lock-open"
                color = DS.Colors.destructive
                bgColor = DS.Colors.destructiveBackground
            } else if data.unlockedCount > 0 {
                label = "\(data.unlockedCount) unlocked"
                icon = "lock-open"
                color = DS.Colors.warningForeground
                bgColor = DS.Colors.warningBackground
            } else {
                label = data.totalLocks == 1 ? "Locked" : "\(data.lockedCount)/\(data.totalLocks)"
                icon = "lock"
                color = DS.Colors.successForeground
                bgColor = DS.Colors.successBackground
            }

            let tooltip = formatReadingsTooltip(
                title: "Locks: \(data.lockedCount)/\(data.totalLocks) locked",
                readings: data.lockReadings,
                formatValue: { v in
                    switch Int(v) {
                    case 0: return "Unlocked"
                    case 1: return "Locked"
                    case 2: return "Jammed"
                    default: return "Unknown"
                    }
                }
            )
            let item = SummaryItemView(icon: icon, label: label, color: color, bgColor: bgColor, tooltipText: tooltip)
            summaryItems.append(item)
            addSubview(item)
        }

        // Contacts
        if data.totalContacts > 0 {
            let hasOpen = data.openContactCount > 0
            let label = hasOpen ? "\(data.openContactCount) open" : "Closed"
            let color = hasOpen ? DS.Colors.warningForeground : DS.Colors.mutedForeground
            let bgColor = hasOpen ? DS.Colors.warningBackground : DS.Colors.muted
            let tooltip = formatReadingsTooltip(
                title: "Contacts: \(data.openContactCount) open, \(data.closedContactCount) closed",
                readings: data.contactReadings,
                formatValue: { $0 == 0 ? "Closed" : "Open" }
            )
            let item = SummaryItemView(icon: "door-open", label: label, color: color, bgColor: bgColor, tooltipText: tooltip)
            summaryItems.append(item)
            addSubview(item)
        }

        // Low battery
        if data.lowBatteryCount > 0 {
            let label = "\(data.lowBatteryCount) low"
            let tooltip = formatReadingsTooltip(
                title: "Low Battery: \(data.lowBatteryCount) device\(data.lowBatteryCount != 1 ? "s" : "")",
                readings: data.lowBatteryReadings,
                formatValue: { _ in "Low battery" }
            )
            let item = SummaryItemView(icon: "battery-low", label: label, color: DS.Colors.warningForeground, bgColor: DS.Colors.warningBackground, tooltipText: tooltip)
            summaryItems.append(item)
            addSubview(item)
        }

        // Recalculate layout
        let size = intrinsicContentSize
        frame.size.height = size.height
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

// MARK: - Summary Item View

private final class SummaryItemView: NSView {
    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()

    private let labelField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = DS.Typography.labelSmall
        field.textColor = DS.Colors.mutedForeground
        field.lineBreakMode = .byClipping
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }()

    private let iconSize: CGFloat = 11
    private let padding: CGFloat = 7
    private let spacing: CGFloat = 3
    private let itemHeight: CGFloat = 18

    init(icon: String, label text: String, color: NSColor, bgColor: NSColor = DS.Colors.muted, tooltipText: String? = nil) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = itemHeight / 2
        layer?.backgroundColor = bgColor.withAlphaComponent(1.0).cgColor

        addSubview(iconView)
        addSubview(labelField)

        // Set icon
        if let phosphorIcon = PhosphorIcon.regular(icon) {
            iconView.image = phosphorIcon
        }
        iconView.contentTintColor = color

        // Set label text, then measure
        labelField.stringValue = text
        labelField.textColor = color
        labelField.sizeToFit()

        let labelWidth = ceil(labelField.frame.width)
        let labelHeight = ceil(labelField.frame.height)
        let totalWidth = padding + iconSize + spacing + labelWidth + padding

        // Set frames
        frame = NSRect(x: 0, y: 0, width: totalWidth, height: itemHeight)
        iconView.frame = NSRect(x: padding, y: (itemHeight - iconSize) / 2, width: iconSize, height: iconSize)
        labelField.frame = NSRect(x: padding + iconSize + spacing, y: (itemHeight - labelHeight) / 2, width: labelWidth, height: labelHeight)

        // Set tooltip for hover detail
        if let tooltipText = tooltipText {
            self.toolTip = tooltipText
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        return frame.size
    }
}
