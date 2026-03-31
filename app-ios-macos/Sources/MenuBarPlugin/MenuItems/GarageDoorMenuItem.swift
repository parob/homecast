//
//  GarageDoorMenuItem.swift
//  Homecast
//
//  Menu item view for garage doors
//

import AppKit

/// Menu item view for garage doors
/// Layout: [Icon] [Name] [Open/Closed/Opening...] [Button]
/// Height: 28px (DS.ControlSize.menuItemHeight)
final class GarageDoorMenuItem: HighlightingMenuItemView {
    // MARK: - Properties

    /// Door state: 0 = open, 1 = closed, 2 = opening, 3 = closing, 4 = stopped
    private var doorState: Int = 4
    private var targetState: Int = 1

    // MARK: - UI Components

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
        addSubview(actionButton)

        actionButton.target = self
        actionButton.action = #selector(handleButtonPress)

        layoutSubviews()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        if layoutUnreachable() { return }
        super.layoutSubviews()

        let height = frame.height
        let iconSize = DS.ControlSize.iconMedium
        let switchWidth = DS.ControlSize.switchWidth

        // Icon on left
        let iconY = (height - iconSize) / 2
        iconView.frame = NSRect(x: DS.Spacing.menuItemPadding, y: iconY, width: iconSize, height: iconSize)

        // Button on right (using switch width for consistency)
        let buttonX = frame.width - DS.Spacing.menuItemPadding - switchWidth
        let buttonY = (height - iconSize) / 2
        actionButton.frame = NSRect(x: buttonX, y: buttonY, width: switchWidth, height: iconSize)

        // State label before button
        let stateLabelWidth: CGFloat = 60
        let stateLabelX = buttonX - stateLabelWidth - DS.Spacing.sm
        stateLabel.frame = NSRect(x: stateLabelX, y: (height - 14) / 2, width: stateLabelWidth, height: 14)

        // Name label fills remaining space
        let labelX = DS.Spacing.menuItemPadding + iconSize + DS.Spacing.sm
        let labelWidth = stateLabelX - labelX - DS.Spacing.xs
        nameLabel.frame = NSRect(x: labelX, y: (height - 17) / 2, width: max(0, labelWidth), height: 17)
    }

    // MARK: - Configuration

    override func configure(with config: MenuItemConfiguration) {
        super.configure(with: config)

        doorState = config.doorState ?? 4
        targetState = config.targetDoorState ?? 1

        guard isReachable else { return }

        actionButton.isEnabled = true

        updateStateLabel()
        updateIcon()
        updateButton()
    }

    // MARK: - State Updates

    override func updateCharacteristic(_ type: String, value: Any) {
        let typeLower = type.lowercased()

        if typeLower == "currentdoorstate" || (typeLower.contains("door") && typeLower.contains("current")) {
            if let intValue = value as? Int {
                doorState = intValue
            }
            updateStateLabel()
            updateIcon()
            updateButton()
        }

        if typeLower == "targetdoorstate" || (typeLower.contains("door") && typeLower.contains("target")) {
            if let intValue = value as? Int {
                targetState = intValue
            }
            updateButton()
        }
    }

    override func updateReachableAppearance() {
        super.updateReachableAppearance()

        actionButton.isEnabled = isReachable
        actionButton.isHidden = !isReachable

        if isReachable {
            updateStateLabel()
            updateIcon()
        }
        needsLayout = true
    }

    // MARK: - Private

    private func updateStateLabel() {
        switch doorState {
        case 0: // Open
            stateLabel.stringValue = "Open"
            stateLabel.textColor = DS.Colors.warning
        case 1: // Closed
            stateLabel.stringValue = "Closed"
            stateLabel.textColor = DS.Colors.success
        case 2: // Opening
            stateLabel.stringValue = "Opening..."
            stateLabel.textColor = DS.Colors.info
        case 3: // Closing
            stateLabel.stringValue = "Closing..."
            stateLabel.textColor = DS.Colors.info
        case 4: // Stopped
            stateLabel.stringValue = "Stopped"
            stateLabel.textColor = DS.Colors.mutedForeground
        default:
            stateLabel.stringValue = "Unknown"
            stateLabel.textColor = DS.Colors.mutedForeground
        }
    }

    private func updateIcon() {
        guard let state = PhosphorIcon.GarageDoorState(rawValue: doorState) else {
            iconView.image = PhosphorIcon.regular("garage")
            iconView.contentTintColor = DS.Colors.mutedForeground
            return
        }

        iconView.image = PhosphorIcon.iconForGarageDoorState(state)

        switch state {
        case .open:
            iconView.contentTintColor = DS.Colors.warning
        case .closed:
            iconView.contentTintColor = DS.Colors.success
        case .opening, .closing:
            iconView.contentTintColor = DS.Colors.info
        case .stopped:
            iconView.contentTintColor = DS.Colors.mutedForeground
        }
    }

    private func updateButton() {
        // Show appropriate action based on current state
        let iconName: String
        let tintColor: NSColor

        if doorState == 2 || doorState == 3 {
            // Moving - show stop button
            iconName = "stop-circle"
            tintColor = DS.Colors.mutedForeground
        } else if doorState == 0 {
            // Open - show close button
            iconName = "caret-down"
            tintColor = DS.Colors.success
        } else {
            // Closed or stopped - show open button
            iconName = "caret-up"
            tintColor = DS.Colors.warning
        }

        if let icon = PhosphorIcon.fill(iconName) {
            actionButton.image = icon
        } else {
            actionButton.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        }
        actionButton.contentTintColor = tintColor
    }

    @objc private func handleButtonPress() {
        let newTargetState: Int

        if doorState == 2 || doorState == 3 {
            // Moving - stop by setting target to current
            newTargetState = doorState == 2 ? 0 : 1
        } else if doorState == 0 {
            // Open - close
            newTargetState = 1
        } else {
            // Closed or stopped - open
            newTargetState = 0
        }

        setCharacteristic(type: "TargetDoorState", value: newTargetState)
    }
}
