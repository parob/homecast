//
//  LockMenuItem.swift
//  Homecast
//
//  Menu item view for door locks
//

import AppKit

/// Menu item view for door locks
/// Layout: [Icon] [Name] [Locked/Unlocked] [Toggle]
/// Height: 28px (DS.ControlSize.menuItemHeight)
final class LockMenuItem: HighlightingMenuItemView {
    // MARK: - Properties

    /// Lock state: 0 = unsecured, 1 = secured, 2 = jammed, 3 = unknown
    private var lockState: Int = 3

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

        // State label before toggle
        let stateLabelWidth: CGFloat = 60
        let stateLabelX = switchX - stateLabelWidth - DS.Spacing.sm
        stateLabel.frame = NSRect(x: stateLabelX, y: (height - 14) / 2, width: stateLabelWidth, height: 14)

        // Name label fills remaining space
        let labelX = DS.Spacing.md + iconSize + DS.Spacing.sm
        let labelWidth = stateLabelX - labelX - DS.Spacing.xs
        nameLabel.frame = NSRect(x: labelX, y: (height - 17) / 2, width: max(0, labelWidth), height: 17)
    }

    // MARK: - Configuration

    override func configure(with config: MenuItemConfiguration) {
        super.configure(with: config)

        lockState = config.lockState ?? 3

        guard isReachable else { return }

        let isLocked = lockState == 1
        toggle.setOn(isLocked, animated: false)
        toggle.isEnabled = lockState != 2 // Disable if jammed

        updateStateLabel()
        updateIcon()
    }

    // MARK: - State Updates

    override func updateCharacteristic(_ type: String, value: Any) {
        let typeLower = type.lowercased()

        if typeLower == "lockcurrentstate" || typeLower.contains("lock") && typeLower.contains("current") {
            if let intValue = value as? Int {
                lockState = intValue
            }

            let isLocked = lockState == 1
            toggle.setOn(isLocked, animated: true)
            toggle.isEnabled = isReachable && lockState != 2

            updateStateLabel()
            updateIcon()
        }
    }

    override func updateReachableAppearance() {
        super.updateReachableAppearance()

        toggle.isEnabled = isReachable && lockState != 2
        toggle.isHidden = !isReachable

        if isReachable {
            updateStateLabel()
            updateIcon()
        }
        needsLayout = true
    }

    // MARK: - Private

    private func updateStateLabel() {
        switch lockState {
        case 0: // Unsecured
            stateLabel.stringValue = "Unlocked"
            stateLabel.textColor = DS.Colors.lockUnlocked
        case 1: // Secured
            stateLabel.stringValue = "Locked"
            stateLabel.textColor = DS.Colors.lockLocked
        case 2: // Jammed
            stateLabel.stringValue = "Jammed"
            stateLabel.textColor = DS.Colors.destructive
        default: // Unknown
            stateLabel.stringValue = "Unknown"
            stateLabel.textColor = DS.Colors.mutedForeground
        }
    }

    private func updateIcon() {
        guard let state = PhosphorIcon.LockState(rawValue: lockState) else {
            iconView.image = PhosphorIcon.regular("lock")
            iconView.contentTintColor = DS.Colors.mutedForeground
            return
        }

        iconView.image = PhosphorIcon.iconForLockState(state)

        switch state {
        case .locked:
            iconView.contentTintColor = DS.Colors.lockLocked
        case .unlocked:
            iconView.contentTintColor = DS.Colors.lockUnlocked
        case .jammed:
            iconView.contentTintColor = DS.Colors.destructive
        case .unknown:
            iconView.contentTintColor = DS.Colors.mutedForeground
        }
    }

    @objc private func toggleChanged(_ sender: ToggleSwitch) {
        // isOn = true means lock, false means unlock
        let targetState = sender.isOn ? 1 : 0
        setCharacteristic(type: "LockTargetState", value: targetState)
    }
}
