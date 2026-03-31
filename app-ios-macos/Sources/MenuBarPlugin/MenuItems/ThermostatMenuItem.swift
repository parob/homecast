//
//  ThermostatMenuItem.swift
//  Homecast
//
//  Menu item for thermostat controls (Off/Heat/Cool/Auto modes + target temperature)
//  Matches itsyhome's thermostat UI with mode buttons and +/- temperature steppers
//

import AppKit

/// Menu item view for thermostats with mode selection and temperature control
/// Layout (collapsed): [Icon] [Name] [Current Temp] [Toggle]
/// Layout (expanded):  [Icon] [Name] [Current Temp] [Toggle]
///                     [Cool] [Heat] [Auto]        [-] 20° [+]
final class ThermostatMenuItem: HighlightingMenuItemView {
    // MARK: - Properties

    private var currentTemp: Double = 20.0
    private var targetTemp: Double = 21.0
    private var heatingThreshold: Double = 18.0
    private var coolingThreshold: Double = 24.0
    /// Current state: 0 = off, 1 = heating, 2 = cooling
    private var currentState: Int = 0
    /// Target mode: 0 = off, 1 = heat, 2 = cool, 3 = auto
    private var targetState: Int = 0
    private var hasThresholds: Bool = false
    /// Whether this is a HeaterCooler (AC) device vs standard thermostat
    private var isHeaterCooler: Bool = false

    private let collapsedHeight: CGFloat = DS.ControlSize.menuItemHeight
    private let expandedHeight: CGFloat = DS.ControlSize.menuItemHeight + 36

    // Remember last active mode when toggling off/on
    private var lastActiveMode: Int = 1  // Default to heat

    // MARK: - UI Components

    private let tempLabel: NSTextField = {
        let label = NSTextField(labelWithString: "--°")
        label.font = DS.Typography.labelSmall
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }()

    private let powerToggle = ToggleSwitch()

    // Controls row (shown when not off)
    private let controlsRow = NSView()

    // Mode buttons
    private var modeButtonGroup: ModeButtonGroup!
    private var modeButtonCool: ModeButton!
    private var modeButtonHeat: ModeButton!
    private var modeButtonAuto: ModeButton!

    // Single temp control (Heat/Cool modes): [-] 20° [+]
    private let singleTempContainer = NSView()
    private var minusButton: NSButton!
    private let targetLabel: NSTextField = {
        let label = NSTextField(labelWithString: "20°")
        label.font = DS.Typography.labelSmall
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }()
    private var plusButton: NSButton!

    // Range control (Auto mode): -18+ -24+
    private let rangeTempContainer = NSView()
    private var heatMinusButton: NSButton!
    private let heatLabel: NSTextField = {
        let label = NSTextField(labelWithString: "18°")
        label.font = DS.Typography.labelSmall
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }()
    private var heatPlusButton: NSButton!
    private var coolMinusButton: NSButton!
    private let coolLabel: NSTextField = {
        let label = NSTextField(labelWithString: "24°")
        label.font = DS.Typography.labelSmall
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }()
    private var coolPlusButton: NSButton!

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: DS.ControlSize.menuItemWidth, height: collapsedHeight))
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
        // Current temp label
        addSubview(tempLabel)

        // Power toggle
        powerToggle.target = self
        powerToggle.action = #selector(powerToggleChanged(_:))
        addSubview(powerToggle)

        // Controls row (initially hidden)
        controlsRow.isHidden = true
        addSubview(controlsRow)

        // Mode buttons container
        let labelX = DS.Spacing.md + DS.ControlSize.iconMedium + DS.Spacing.sm
        let containerWidth = ModeButtonGroup.widthForButtons(count: 3)
        modeButtonGroup = ModeButtonGroup(frame: NSRect(x: labelX, y: 3, width: containerWidth, height: 22))

        modeButtonCool = modeButtonGroup.addButton(title: "Cool", color: DS.Colors.thermostatCool, tag: 2)
        modeButtonHeat = modeButtonGroup.addButton(title: "Heat", color: DS.Colors.thermostatHeat, tag: 1)
        modeButtonAuto = modeButtonGroup.addButton(title: "Auto", color: DS.Colors.success, tag: 3)

        modeButtonCool.target = self
        modeButtonCool.action = #selector(modeChanged(_:))
        modeButtonHeat.target = self
        modeButtonHeat.action = #selector(modeChanged(_:))
        modeButtonAuto.target = self
        modeButtonAuto.action = #selector(modeChanged(_:))

        // Set initial selection
        modeButtonHeat.isSelected = true

        controlsRow.addSubview(modeButtonGroup)

        // Single temperature control: [-] 20° [+]
        let singleTempX = DS.ControlSize.menuItemWidth - DS.Spacing.md - 78
        singleTempContainer.frame = NSRect(x: singleTempX, y: 0, width: 78, height: 26)

        minusButton = StepperButton.create(title: "−", size: .regular)
        minusButton.frame.origin = NSPoint(x: 0, y: 4)
        minusButton.target = self
        minusButton.action = #selector(decreaseTemp(_:))
        singleTempContainer.addSubview(minusButton)

        targetLabel.frame = NSRect(x: 22, y: 5, width: 32, height: 17)
        singleTempContainer.addSubview(targetLabel)

        plusButton = StepperButton.create(title: "+", size: .regular)
        plusButton.frame.origin = NSPoint(x: 56, y: 4)
        plusButton.target = self
        plusButton.action = #selector(increaseTemp(_:))
        singleTempContainer.addSubview(plusButton)

        controlsRow.addSubview(singleTempContainer)

        // Range temperature control: -18+ -24+ (for Auto mode with thresholds)
        let miniBtn: CGFloat = 11
        let miniLabel: CGFloat = 24
        let miniStepper = miniBtn + miniLabel + miniBtn  // 44
        let rangeWidth = miniStepper * 2 + 6  // 94
        let rangeTempX = DS.ControlSize.menuItemWidth - DS.Spacing.md - rangeWidth
        rangeTempContainer.frame = NSRect(x: rangeTempX, y: 1, width: rangeWidth, height: 26)
        rangeTempContainer.isHidden = true

        // Heat stepper (left): -18+
        heatMinusButton = StepperButton.create(title: "−", size: .mini)
        heatMinusButton.frame.origin = NSPoint(x: 0, y: 8)
        heatMinusButton.target = self
        heatMinusButton.action = #selector(decreaseHeatThreshold(_:))
        rangeTempContainer.addSubview(heatMinusButton)

        heatLabel.frame = NSRect(x: miniBtn, y: 6, width: miniLabel, height: 14)
        rangeTempContainer.addSubview(heatLabel)

        heatPlusButton = StepperButton.create(title: "+", size: .mini)
        heatPlusButton.frame.origin = NSPoint(x: miniBtn + miniLabel, y: 8)
        heatPlusButton.target = self
        heatPlusButton.action = #selector(increaseHeatThreshold(_:))
        rangeTempContainer.addSubview(heatPlusButton)

        // Cool stepper (right): -24+
        let coolX = miniStepper + 6
        coolMinusButton = StepperButton.create(title: "−", size: .mini)
        coolMinusButton.frame.origin = NSPoint(x: coolX, y: 8)
        coolMinusButton.target = self
        coolMinusButton.action = #selector(decreaseCoolThreshold(_:))
        rangeTempContainer.addSubview(coolMinusButton)

        coolLabel.frame = NSRect(x: coolX + miniBtn, y: 6, width: miniLabel, height: 14)
        rangeTempContainer.addSubview(coolLabel)

        coolPlusButton = StepperButton.create(title: "+", size: .mini)
        coolPlusButton.frame.origin = NSPoint(x: coolX + miniBtn + miniLabel, y: 8)
        coolPlusButton.target = self
        coolPlusButton.action = #selector(increaseCoolThreshold(_:))
        rangeTempContainer.addSubview(coolPlusButton)

        controlsRow.addSubview(rangeTempContainer)

        // Don't close menu on click
        closesMenuOnAction = false
        onAction = { [weak self] in
            self?.togglePower()
        }

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

        // Top row: icon, name, current temp, power toggle
        let topRowY = height - collapsedHeight

        // Icon on left
        let iconY = topRowY + (collapsedHeight - iconSize) / 2
        iconView.frame = NSRect(x: DS.Spacing.menuItemPadding, y: iconY, width: iconSize, height: iconSize)

        // Power toggle on right
        let switchX = frame.width - DS.Spacing.menuItemPadding - switchWidth
        let switchY = topRowY + (collapsedHeight - switchHeight) / 2
        powerToggle.frame = NSRect(x: switchX, y: switchY, width: switchWidth, height: switchHeight)

        // Current temp before toggle
        let tempWidth: CGFloat = 31
        let tempX = switchX - tempWidth - DS.Spacing.sm
        let labelY = topRowY + (collapsedHeight - 17) / 2
        tempLabel.frame = NSRect(x: tempX, y: labelY - 2, width: tempWidth, height: 17)

        // Name label fills remaining space
        let labelX = DS.Spacing.md + iconSize + DS.Spacing.sm
        let labelWidth = tempX - labelX - DS.Spacing.xs
        nameLabel.frame = NSRect(x: labelX, y: labelY, width: max(0, labelWidth), height: 17)

        // Controls row
        controlsRow.frame = NSRect(x: 0, y: DS.Spacing.sm, width: DS.ControlSize.menuItemWidth, height: 26)

        // Hide state label
        stateLabel.isHidden = true
    }

    // MARK: - Configuration

    override func configure(with config: MenuItemConfiguration) {
        super.configure(with: config)

        currentTemp = config.currentTemperature ?? 20.0
        targetState = config.hvacMode ?? 0
        heatingThreshold = config.heatingThreshold ?? 18.0
        coolingThreshold = config.coolingThreshold ?? 24.0
        hasThresholds = config.hasThresholds
        isHeaterCooler = config.isHeaterCooler

        // For HeaterCooler devices, hvacMode is always 1/2/3 (no off mode).
        // On/off is determined by the Active characteristic (exposed as powerState).
        if isHeaterCooler {
            if let active = config.powerState, !active {
                // Device is inactive — remember the mode but show as off
                if targetState != 0 {
                    lastActiveMode = targetState
                }
                targetState = 0
            }

            // Use the appropriate threshold as target temp
            switch targetState {
            case 1: targetTemp = heatingThreshold
            case 2: targetTemp = coolingThreshold
            default: targetTemp = coolingThreshold
            }
        } else {
            targetTemp = config.targetTemperature ?? 21.0
        }

        if targetState != 0 {
            lastActiveMode = targetState
        }

        guard isReachable else { return }

        powerToggle.setOn(targetState != 0, animated: false)
        powerToggle.isEnabled = true

        updateModeButtons()
        updateUI()
    }

    // MARK: - State Updates

    override func updateCharacteristic(_ type: String, value: Any) {
        let typeLower = type.lowercased().replacingOccurrences(of: "_", with: "")

        if typeLower == "currenttemperature" || (typeLower.contains("current") && typeLower.contains("temp")) {
            if let doubleValue = value as? Double {
                currentTemp = doubleValue
            } else if let intValue = value as? Int {
                currentTemp = Double(intValue)
            }
            tempLabel.stringValue = formatTemp(currentTemp, decimals: 1)
        }

        if typeLower == "targettemperature" || (typeLower.contains("target") && typeLower.contains("temp")) {
            if let doubleValue = value as? Double {
                targetTemp = doubleValue
            } else if let intValue = value as? Int {
                targetTemp = Double(intValue)
            }
            targetLabel.stringValue = formatTemp(targetTemp)
        }

        // HeaterCooler Active characteristic (on/off)
        if isHeaterCooler && (typeLower == "active" || typeLower == "powerstate") {
            var isActive = false
            if let boolValue = value as? Bool {
                isActive = boolValue
            } else if let intValue = value as? Int {
                isActive = intValue != 0
            }
            if !isActive && targetState != 0 {
                lastActiveMode = targetState
                targetState = 0
                updateModeButtons()
                updateUI()
            } else if isActive && targetState == 0 {
                targetState = lastActiveMode
                updateModeButtons()
                updateUI()
            }
        }

        if typeLower == "heatingcoolingcurrentstate" || typeLower == "currentheatingcoolingstate" {
            if let intValue = value as? Int {
                currentState = intValue
                updateStateIcon()
            }
        }

        // HeaterCooler current state (0=inactive, 1=idle, 2=heating, 3=cooling)
        if typeLower == "currentheatercoolerstate" || typeLower.contains("currentheatercooler") {
            if let intValue = value as? Int {
                // Map to thermostat-style: 0=off, 1=heating, 2=cooling
                switch intValue {
                case 2: currentState = 1  // heating
                case 3: currentState = 2  // cooling
                default: currentState = 0 // inactive/idle
                }
                updateStateIcon()
            }
        }

        if typeLower == "targetheatingcoolingstate" || typeLower == "heatingcoolingtarget" ||
           typeLower.contains("hvac") || typeLower.contains("mode") {
            if let intValue = value as? Int {
                targetState = intValue
                if intValue != 0 {
                    lastActiveMode = intValue
                }
                updateModeButtons()
                updateUI()
            }
        }

        // HeaterCooler target state (0=auto, 1=heat, 2=cool)
        if typeLower == "targetheatercoolerstate" || typeLower.contains("heatercoolertarget") {
            if let intValue = value as? Int {
                // Map to thermostat-style: 0=off, 1=heat, 2=cool, 3=auto
                let mappedMode: Int
                switch intValue {
                case 0: mappedMode = 3  // auto
                case 1: mappedMode = 1  // heat
                case 2: mappedMode = 2  // cool
                default: mappedMode = intValue
                }
                targetState = mappedMode
                if mappedMode != 0 {
                    lastActiveMode = mappedMode
                }
                updateModeButtons()
                updateUI()
            }
        }

        if typeLower == "coolingthresholdtemperature" || typeLower.contains("coolingthreshold") ||
           typeLower == "cooling_threshold" {
            if let doubleValue = value as? Double {
                coolingThreshold = doubleValue
            } else if let intValue = value as? Int {
                coolingThreshold = Double(intValue)
            }
            coolLabel.stringValue = formatTemp(coolingThreshold)
            // For HeaterCooler in cool mode, also update the single target display
            if isHeaterCooler && targetState == 2 {
                targetTemp = coolingThreshold
                targetLabel.stringValue = formatTemp(targetTemp)
            }
        }

        if typeLower == "heatingthresholdtemperature" || typeLower.contains("heatingthreshold") ||
           typeLower == "heating_threshold" {
            if let doubleValue = value as? Double {
                heatingThreshold = doubleValue
            } else if let intValue = value as? Int {
                heatingThreshold = Double(intValue)
            }
            heatLabel.stringValue = formatTemp(heatingThreshold)
            // For HeaterCooler in heat mode, also update the single target display
            if isHeaterCooler && targetState == 1 {
                targetTemp = heatingThreshold
                targetLabel.stringValue = formatTemp(targetTemp)
            }
        }
    }

    override func updateReachableAppearance() {
        super.updateReachableAppearance()

        powerToggle.isEnabled = isReachable
        powerToggle.isHidden = !isReachable
        tempLabel.isHidden = !isReachable
        controlsRow.isHidden = !isReachable

        if !isReachable {
            let newHeight = collapsedHeight
            if frame.height != newHeight {
                frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: newHeight)
                enclosingMenuItem?.menu?.itemChanged(enclosingMenuItem!)
            }
        }

        if isReachable {
            updateUI()
        }
        needsLayout = true
    }

    // MARK: - Private

    private func formatTemp(_ temp: Double, decimals: Int = 0) -> String {
        if decimals > 0 {
            return String(format: "%.1f°", temp)
        } else {
            return String(format: "%.0f°", temp)
        }
    }

    private func updateUI() {
        let isActive = targetState != 0
        powerToggle.setOn(isActive, animated: false)
        controlsRow.isHidden = !isActive

        // Resize frame
        let newHeight = isActive ? expandedHeight : collapsedHeight
        if frame.height != newHeight {
            frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: newHeight)
            enclosingMenuItem?.menu?.itemChanged(enclosingMenuItem!)
        }

        // Show range control in Auto mode with thresholds, single control otherwise
        let showRange = targetState == 3 && hasThresholds
        singleTempContainer.isHidden = showRange
        rangeTempContainer.isHidden = !showRange

        // Update labels
        tempLabel.stringValue = formatTemp(currentTemp, decimals: 1)
        targetLabel.stringValue = formatTemp(targetTemp)
        heatLabel.stringValue = formatTemp(heatingThreshold)
        coolLabel.stringValue = formatTemp(coolingThreshold)

        updateStateIcon()
        layoutSubviews()
    }

    private func updateStateIcon() {
        let iconName = PhosphorIcon.defaultIconName(for: "thermostat")

        if targetState == 0 {
            iconView.image = PhosphorIcon.regular(iconName)
            iconView.contentTintColor = DS.Colors.mutedForeground
            return
        }

        // Show icon based on current state (what it's actually doing)
        let color: NSColor
        switch currentState {
        case 1: // Heating
            color = DS.Colors.thermostatHeat
        case 2: // Cooling
            color = DS.Colors.thermostatCool
        default:
            // Fall back to target state color
            switch targetState {
            case 1: color = DS.Colors.thermostatHeat
            case 2: color = DS.Colors.thermostatCool
            case 3: color = DS.Colors.success
            default: color = DS.Colors.mutedForeground
            }
        }

        iconView.image = PhosphorIcon.fill(iconName)
        iconView.contentTintColor = color
    }

    private func updateModeButtons() {
        modeButtonHeat.isSelected = (targetState == 1)
        modeButtonCool.isSelected = (targetState == 2)
        modeButtonAuto.isSelected = (targetState == 3)
    }

    private func togglePower() {
        if targetState == 0 {
            // Turn on - restore last active mode
            setMode(lastActiveMode)
        } else {
            // Turn off
            setMode(0)
        }
    }

    private func setMode(_ mode: Int) {
        targetState = mode
        if mode != 0 {
            lastActiveMode = mode
        }

        // For HeaterCooler, update target temp display based on new mode
        if isHeaterCooler && mode != 0 {
            switch mode {
            case 1: // Heat mode - show heating threshold
                targetTemp = heatingThreshold
            case 2: // Cool mode - show cooling threshold
                targetTemp = coolingThreshold
            default:
                break
            }
            targetLabel.stringValue = formatTemp(targetTemp)
        }

        updateModeButtons()
        updateUI()

        if isHeaterCooler {
            // HeaterCooler uses different characteristic and mode values
            // Our internal: 0=off, 1=heat, 2=cool, 3=auto
            // HeaterCooler: 0=auto, 1=heat, 2=cool (no off in target state)
            if mode == 0 {
                // Turn off via Active characteristic
                setCharacteristic(type: "active", value: 0)
            } else {
                // Turn on and set mode
                setCharacteristic(type: "active", value: 1)
                let heaterCoolerMode: Int
                switch mode {
                case 1: heaterCoolerMode = 1  // heat -> heat
                case 2: heaterCoolerMode = 2  // cool -> cool
                case 3: heaterCoolerMode = 0  // auto -> auto
                default: heaterCoolerMode = 0
                }
                setCharacteristic(type: "target_heater_cooler_state", value: heaterCoolerMode)
            }
        } else {
            // Standard thermostat
            setCharacteristic(type: "heating_cooling_target", value: mode)
        }
    }

    private func setTargetTemp(_ temp: Double) {
        let clamped = min(max(temp, 10), 30)
        targetTemp = clamped
        targetLabel.stringValue = formatTemp(clamped)

        if isHeaterCooler {
            // HeaterCooler devices use threshold temperatures based on mode
            // In cool mode: set cooling_threshold
            // In heat mode: set heating_threshold
            // In auto mode: both are used (handled by range controls)
            switch targetState {
            case 1: // Heat mode
                setCharacteristic(type: "heating_threshold", value: Float(clamped))
            case 2: // Cool mode
                setCharacteristic(type: "cooling_threshold", value: Float(clamped))
            default:
                // Auto mode or other - try both
                setCharacteristic(type: "cooling_threshold", value: Float(clamped))
            }
        } else {
            // Standard thermostat
            setCharacteristic(type: "target_temperature", value: Float(clamped))
        }
    }

    private func setHeatingThreshold(_ temp: Double) {
        let maxHeat = coolingThreshold - 1
        let clamped = min(max(temp, 10), maxHeat)
        heatingThreshold = clamped
        heatLabel.stringValue = formatTemp(clamped)
        setCharacteristic(type: "heating_threshold", value: Float(clamped))
    }

    private func setCoolingThreshold(_ temp: Double) {
        let minCool = heatingThreshold + 1
        let clamped = min(max(temp, minCool), 30)
        coolingThreshold = clamped
        coolLabel.stringValue = formatTemp(clamped)
        setCharacteristic(type: "cooling_threshold", value: Float(clamped))
    }

    // MARK: - Actions

    @objc private func powerToggleChanged(_ sender: ToggleSwitch) {
        if sender.isOn {
            setMode(lastActiveMode)
        } else {
            setMode(0)
        }
    }

    @objc private func modeChanged(_ sender: ModeButton) {
        setMode(sender.tag)
    }

    @objc private func decreaseTemp(_ sender: NSButton) {
        setTargetTemp(targetTemp - 1)
    }

    @objc private func increaseTemp(_ sender: NSButton) {
        setTargetTemp(targetTemp + 1)
    }

    @objc private func decreaseHeatThreshold(_ sender: NSButton) {
        setHeatingThreshold(heatingThreshold - 1)
    }

    @objc private func increaseHeatThreshold(_ sender: NSButton) {
        setHeatingThreshold(heatingThreshold + 1)
    }

    @objc private func decreaseCoolThreshold(_ sender: NSButton) {
        setCoolingThreshold(coolingThreshold - 1)
    }

    @objc private func increaseCoolThreshold(_ sender: NSButton) {
        setCoolingThreshold(coolingThreshold + 1)
    }
}
