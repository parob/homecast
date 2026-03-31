//
//  SecuritySystemMenuItem.swift
//  Homecast
//
//  Menu item for security system controls (Stay/Away/Night/Off modes)
//  Two-row layout matching thermostat with mode buttons
//

import AppKit

/// Menu item view for security systems with mode selection
/// Layout: Row 1: [Icon] [Name]                    [State Label]
///         Row 2:        [Home] [Away] [Night] [Off]
final class SecuritySystemMenuItem: HighlightingMenuItemView {
    // MARK: - Properties

    /// Current state: 0=Stay, 1=Away, 2=Night, 3=Disarmed, 4=Triggered
    private var currentState: Int = 3  // Default: Disarmed
    private var targetState: Int = 3

    private let fixedHeight: CGFloat = 64  // Two-row layout like thermostat

    // MARK: - UI Components

    // Controls row (bottom row with mode buttons)
    private let controlsRow = NSView()

    // Mode buttons
    private var modeButtonGroup: ModeButtonGroup!
    private var homeButton: ModeButton!   // Stay Arm (0)
    private var awayButton: ModeButton!   // Away Arm (1)
    private var nightButton: ModeButton!  // Night Arm (2)
    private var offButton: ModeButton!    // Disarmed (3)

    // MARK: - Colors

    /// Blue for Stay Arm (Home mode)
    private static let colorStayArm = DS.Colors.info
    /// Green for Away Arm
    private static let colorAwayArm = DS.Colors.success
    /// Purple for Night Arm
    private static let colorNightArm = NSColor(red: 0.58, green: 0.44, blue: 0.86, alpha: 1)
    /// Gray for Disarmed
    private static let colorDisarmed = DS.Colors.mutedForeground
    /// Red for Triggered
    private static let colorTriggered = DS.Colors.destructive

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: DS.ControlSize.menuItemWidth, height: fixedHeight))
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
        // Controls row
        addSubview(controlsRow)

        // Mode buttons container
        let labelX = DS.Spacing.md + DS.ControlSize.iconMedium + DS.Spacing.sm
        let containerWidth = ModeButtonGroup.widthForButtons(count: 4)
        modeButtonGroup = ModeButtonGroup(frame: NSRect(x: labelX, y: 3, width: containerWidth, height: 22))

        homeButton = modeButtonGroup.addButton(title: "Home", color: Self.colorStayArm, tag: 0)
        awayButton = modeButtonGroup.addButton(title: "Away", color: Self.colorAwayArm, tag: 1)
        nightButton = modeButtonGroup.addButton(title: "Night", color: Self.colorNightArm, tag: 2)
        offButton = modeButtonGroup.addButton(title: "Off", color: Self.colorDisarmed, tag: 3)

        homeButton.target = self
        homeButton.action = #selector(modeChanged(_:))
        awayButton.target = self
        awayButton.action = #selector(modeChanged(_:))
        nightButton.target = self
        nightButton.action = #selector(modeChanged(_:))
        offButton.target = self
        offButton.action = #selector(modeChanged(_:))

        // Set initial selection
        offButton.isSelected = true

        controlsRow.addSubview(modeButtonGroup)

        // Don't close menu on click
        closesMenuOnAction = false

        layoutSubviews()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        if layoutUnreachable() { return }
        super.layoutSubviews()

        let height = frame.height
        let collapsedHeight = DS.ControlSize.menuItemHeight
        let iconSize = DS.ControlSize.iconMedium

        // Top row: icon, name, state label
        let topRowY = height - collapsedHeight

        // Icon on left
        let iconY = topRowY + (collapsedHeight - iconSize) / 2
        iconView.frame = NSRect(x: DS.Spacing.menuItemPadding, y: iconY, width: iconSize, height: iconSize)

        // State label on right
        let stateWidth: CGFloat = 60
        let stateX = frame.width - DS.Spacing.menuItemPadding - stateWidth
        let labelY = topRowY + (collapsedHeight - 17) / 2
        stateLabel.frame = NSRect(x: stateX, y: labelY - 2, width: stateWidth, height: 17)
        stateLabel.isHidden = false

        // Name label fills remaining space
        let labelX = DS.Spacing.md + iconSize + DS.Spacing.sm
        let labelWidth = stateX - labelX - DS.Spacing.xs
        nameLabel.frame = NSRect(x: labelX, y: labelY, width: max(0, labelWidth), height: 17)

        // Controls row (bottom)
        controlsRow.frame = NSRect(x: 0, y: DS.Spacing.sm, width: DS.ControlSize.menuItemWidth, height: 26)
    }

    // MARK: - Configuration

    override func configure(with config: MenuItemConfiguration) {
        super.configure(with: config)

        // Extract security state from config properties
        if let current = config.securityCurrentState {
            currentState = current
        }
        if let target = config.securityTargetState {
            targetState = target
        }

        guard isReachable else { return }

        updateModeButtons()
        updateStateLabel()
        updateIcon()
    }

    // MARK: - State Updates

    override func updateCharacteristic(_ type: String, value: Any) {
        let typeLower = type.lowercased().replacingOccurrences(of: "_", with: "")

        if typeLower.contains("securitysystemcurrentstate") || typeLower == "securitysystemcurrentstate" {
            if let intValue = value as? Int {
                currentState = intValue
                updateStateLabel()
                updateIcon()
            }
        }

        if typeLower.contains("securitysystemtargetstate") || typeLower == "securitysystemtargetstate" {
            if let intValue = value as? Int {
                targetState = intValue
                updateModeButtons()
            }
        }
    }

    override func updateReachableAppearance() {
        super.updateReachableAppearance()

        controlsRow.isHidden = !isReachable

        if !isReachable {
            let newHeight = DS.ControlSize.menuItemHeight
            if frame.height != newHeight {
                frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: newHeight)
                enclosingMenuItem?.menu?.itemChanged(enclosingMenuItem!)
            }
        } else {
            let newHeight = fixedHeight
            if frame.height != newHeight {
                frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: newHeight)
                enclosingMenuItem?.menu?.itemChanged(enclosingMenuItem!)
            }
            updateButtonsEnabled()
            updateIcon()
            updateStateLabel()
        }
        needsLayout = true
    }

    // MARK: - Private

    private func updateStateLabel() {
        let label: String
        let color: NSColor

        if !isReachable {
            stateLabel.stringValue = "Unreachable"
            stateLabel.textColor = DS.Colors.mutedForeground
            return
        }

        switch currentState {
        case 0:  // Stay Arm
            label = "Home"
            color = Self.colorStayArm
        case 1:  // Away Arm
            label = "Away"
            color = Self.colorAwayArm
        case 2:  // Night Arm
            label = "Night"
            color = Self.colorNightArm
        case 3:  // Disarmed
            label = "Off"
            color = Self.colorDisarmed
        case 4:  // Triggered
            label = "ALARM!"
            color = Self.colorTriggered
        default:
            label = "Unknown"
            color = DS.Colors.mutedForeground
        }

        stateLabel.stringValue = label
        stateLabel.textColor = color
    }

    private func updateIcon() {
        let securityState = PhosphorIcon.SecurityState(rawValue: currentState) ?? .disarmed
        let iconName = PhosphorIcon.iconNameForSecurityState(securityState)

        // Use fill variant when armed, regular when disarmed
        let isFilled = currentState != 3 && isReachable
        if let icon = PhosphorIcon.icon(iconName, filled: isFilled) {
            iconView.image = icon
        }

        // Set icon color based on state
        if !isReachable {
            iconView.contentTintColor = DS.Colors.mutedForeground
        } else {
            switch currentState {
            case 0:  // Stay Arm
                iconView.contentTintColor = Self.colorStayArm
            case 1:  // Away Arm
                iconView.contentTintColor = Self.colorAwayArm
            case 2:  // Night Arm
                iconView.contentTintColor = Self.colorNightArm
            case 3:  // Disarmed
                iconView.contentTintColor = DS.Colors.mutedForeground
            case 4:  // Triggered
                iconView.contentTintColor = Self.colorTriggered
            default:
                iconView.contentTintColor = DS.Colors.iconForeground
            }
        }
    }

    private func updateModeButtons() {
        homeButton.isSelected = (targetState == 0)
        awayButton.isSelected = (targetState == 1)
        nightButton.isSelected = (targetState == 2)
        offButton.isSelected = (targetState == 3)
    }

    private func updateButtonsEnabled() {
        let enabled = isReachable
        homeButton.isDisabled = !enabled
        awayButton.isDisabled = !enabled
        nightButton.isDisabled = !enabled
        offButton.isDisabled = !enabled
    }

    private func setTargetState(_ state: Int) {
        targetState = state
        updateModeButtons()

        // Send characteristic update
        setCharacteristic(type: "security_system_target_state", value: state)
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: ModeButton) {
        setTargetState(sender.tag)
    }
}
