//
//  GroupMenuItem.swift
//  Homecast
//
//  Menu item view for service groups with partial state display and color controls
//

import AppKit

/// Menu item view for service groups with partial state display
/// Layout (collapsed): [Icon] [Name] [Status?] [ColorCircle?] [Slider?] [Toggle]
/// Layout (expanded):  [Icon] [Name] [Status?] [ColorCircle?] [Slider?] [Toggle]
///                     [        Color Picker Row        ]
/// Height: 28px base, expands for color picker
final class GroupMenuItem: HighlightingMenuItemView {
    // MARK: - Properties

    private var isOn: Bool = false
    private var onCount: Int = 0
    private var accessoryCount: Int = 0
    private var brightness: Int?
    private var position: Int?
    private var hasBrightness: Bool = false
    private var hasPosition: Bool = false
    private var groupCategory: String = "Lightbulb"

    // Color properties
    private var hasRGB: Bool = false
    private var hasColorTemp: Bool = false
    private var hasColor: Bool { hasRGB || hasColorTemp }
    private var hue: Double = 0
    private var saturation: Double = 100
    private var colorTemp: Double = 300
    private var colorTempMin: Double = 153
    private var colorTempMax: Double = 500
    private var isColorPickerExpanded: Bool = false

    private let collapsedHeight: CGFloat = DS.ControlSize.menuItemHeight
    private var expandedHeight: CGFloat = DS.ControlSize.menuItemHeight

    // MARK: - UI Components

    private let toggle = ToggleSwitch()
    private let slider = ModernSlider()
    private let colorCircle = ClickableColorCircleView()
    private let colorControlsRow = NSView()
    private var colorPickerView: NSView?

    // MARK: - Initialization

    init(hasSlider: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: DS.ControlSize.menuItemWidth, height: DS.ControlSize.menuItemHeight))
        self.hasBrightness = hasSlider
        self.hasPosition = false
        setupViews()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    convenience init() {
        self.init(hasSlider: false)
    }

    // MARK: - Setup

    private func setupViews() {
        addSubview(toggle)
        addSubview(slider)

        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))

        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = false
        slider.progressTintColor = DS.Colors.sliderLight
        slider.isHidden = true

        // Color circle
        colorCircle.wantsLayer = true
        colorCircle.layer?.cornerRadius = 7
        colorCircle.layer?.backgroundColor = NSColor.white.cgColor
        colorCircle.layer?.borderColor = NSColor.darkGray.cgColor
        colorCircle.layer?.borderWidth = 1
        colorCircle.isHidden = true
        colorCircle.onClick = { [weak self] in
            self?.toggleColorPicker()
        }
        addSubview(colorCircle)

        // Color controls row (expanded section)
        colorControlsRow.isHidden = true

        layoutSubviews()
    }

    private func setupColorControlsRow() {
        // Remove any existing picker
        colorPickerView?.removeFromSuperview()
        colorControlsRow.removeFromSuperview()

        if hasRGB {
            let picker = ColorWheelPickerView(
                hue: hue,
                saturation: saturation,
                onColorChanged: { [weak self] newHue, newSat, isFinal in
                    self?.handleRGBColorChange(hue: newHue, saturation: newSat, commit: isFinal)
                }
            )
            colorPickerView = picker
        } else if hasColorTemp {
            let picker = ColorTempPickerView(
                currentMired: colorTemp,
                minMired: colorTempMin,
                maxMired: colorTempMax,
                onTempChanged: { [weak self] newMired in
                    self?.setColorTemp(newMired)
                }
            )
            colorPickerView = picker
        }

        if let picker = colorPickerView {
            let size = picker.intrinsicContentSize
            let padding: CGFloat = 4
            colorControlsRow.frame = NSRect(x: 0, y: padding, width: DS.ControlSize.menuItemWidth, height: size.height)
            picker.frame = NSRect(
                x: (DS.ControlSize.menuItemWidth - size.width) / 2,
                y: 0,
                width: size.width,
                height: size.height
            )
            colorControlsRow.addSubview(picker)
            addSubview(colorControlsRow)
            expandedHeight = collapsedHeight + size.height + padding * 2
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if layoutUnreachable() { return }

        let height = frame.height
        let iconSize = DS.ControlSize.iconMedium
        let switchWidth = DS.ControlSize.switchWidth
        let switchHeight = DS.ControlSize.switchHeight
        let sliderWidth = DS.ControlSize.sliderWidth
        let colorCircleSize: CGFloat = 14

        let topRowY = height - collapsedHeight
        let labelX = DS.Spacing.md + iconSize + DS.Spacing.sm
        let labelY = topRowY + (collapsedHeight - 17) / 2

        // Icon on left
        let iconY = topRowY + (collapsedHeight - iconSize) / 2
        iconView.frame = NSRect(x: DS.Spacing.menuItemPadding, y: iconY, width: iconSize, height: iconSize)

        // Toggle on right
        let switchX = frame.width - DS.Spacing.menuItemPadding - switchWidth
        let switchY = topRowY + (collapsedHeight - switchHeight) / 2
        toggle.frame = NSRect(x: switchX, y: switchY, width: switchWidth, height: switchHeight)

        // Slider before toggle (when on and has brightness/position)
        let sliderX = switchX - sliderWidth - DS.Spacing.sm
        let hasSliderVisible = (hasBrightness || hasPosition) && isOn
        if hasSliderVisible {
            let sliderY = topRowY + (collapsedHeight - 12) / 2
            slider.frame = NSRect(x: sliderX, y: sliderY, width: sliderWidth, height: 12)
            slider.isHidden = false
        } else {
            slider.isHidden = true
        }

        // Color circle before slider (when on and has color)
        let showColorCircle = isOn && hasColor
        let colorCircleX = sliderX - colorCircleSize - DS.Spacing.xs
        if showColorCircle {
            let colorCircleY = topRowY + (collapsedHeight - colorCircleSize) / 2
            colorCircle.frame = NSRect(x: colorCircleX, y: colorCircleY, width: colorCircleSize, height: colorCircleSize)
            colorCircle.isHidden = false
        } else {
            colorCircle.isHidden = true
        }

        // Calculate controls start position (leftmost control)
        let controlsStartX: CGFloat
        if hasColor {
            controlsStartX = colorCircleX
        } else if hasBrightness || hasPosition {
            controlsStartX = sliderX
        } else {
            controlsStartX = switchX
        }

        // Status label positioned before controls (itsyhome style: fixed offset, overlaps name)
        let stateLabelWidth: CGFloat = 35
        stateLabel.frame = NSRect(x: controlsStartX - 40, y: labelY, width: stateLabelWidth, height: 17)

        // Name label width based on controls only (status label overlaps if shown)
        var rightEdge = switchX - DS.Spacing.sm
        if hasSliderVisible {
            rightEdge = switchX - sliderWidth - DS.Spacing.sm - DS.Spacing.xs
        }
        if showColorCircle {
            rightEdge = rightEdge - colorCircleSize - DS.Spacing.xs
        }
        nameLabel.frame = NSRect(x: labelX, y: labelY, width: max(0, rightEdge - labelX), height: 17)
    }

    // MARK: - Configuration

    override func configure(with config: MenuItemConfiguration) {
        super.configure(with: config)

        onCount = config.onCount
        accessoryCount = config.accessoryCount
        brightness = config.brightness
        position = config.position
        hasBrightness = config.hasBrightness
        hasPosition = config.hasPosition
        groupCategory = config.groupCategory

        // Color configuration
        hasRGB = config.groupHasRGB
        hasColorTemp = config.groupHasColorTemp
        hue = config.groupHue ?? 0
        saturation = config.groupSaturation ?? 100
        colorTemp = config.groupColorTemperature ?? 300
        colorTempMin = config.groupColorTempMin
        colorTempMax = config.groupColorTempMax

        // Use onCount as source of truth for on/off state (more reliable than isOn flag)
        isOn = onCount > 0

        toggle.setOn(isOn, animated: false)
        toggle.isEnabled = isReachable

        // Update slider
        if hasBrightness, let b = brightness {
            slider.doubleValue = Double(b)
            slider.isEnabled = isOn
        } else if hasPosition, let p = position {
            slider.doubleValue = Double(p)
            slider.progressTintColor = DS.Colors.sliderBlind
            slider.isEnabled = true
        }

        // Setup color picker if group supports color
        if hasColor && colorPickerView == nil {
            setupColorControlsRow()
        }

        updateUI()
    }

    override func updateReachableAppearance() {
        super.updateReachableAppearance()
        toggle.isEnabled = isReachable
        toggle.isHidden = !isReachable
        slider.isHidden = !isReachable || slider.isHidden
        colorCircle.isHidden = !isReachable || colorCircle.isHidden
        if isReachable {
            updateUI()
        }
    }

    // MARK: - State Updates

    override func updateCharacteristic(_ type: String, value: Any) {
        let typeLower = type.lowercased().replacingOccurrences(of: "_", with: "")

        // Power state - update aggregate state
        if typeLower == "powerstate" || typeLower == "on" {
            var newValue = false
            if let boolValue = value as? Bool {
                newValue = boolValue
            } else if let intValue = value as? Int {
                newValue = intValue != 0
            }

            if newValue && onCount == 0 {
                onCount = 1
            } else if !newValue && onCount == accessoryCount && accessoryCount > 0 {
                onCount = accessoryCount - 1
            }

            isOn = onCount > 0
            toggle.setOn(isOn, animated: true)

            if hasBrightness {
                slider.isEnabled = isOn
            }
            updateUI()
        }

        if typeLower == "brightness" {
            if let intValue = value as? Int {
                brightness = intValue
                slider.doubleValue = Double(intValue)
            } else if let doubleValue = value as? Double {
                brightness = Int(doubleValue)
                slider.doubleValue = doubleValue
            }
        }

        if typeLower == "currentposition" || typeLower == "position" {
            if let intValue = value as? Int {
                position = intValue
                slider.doubleValue = Double(intValue)
            } else if let doubleValue = value as? Double {
                position = Int(doubleValue)
                slider.doubleValue = doubleValue
            }
        }

        if typeLower == "hue" {
            if let doubleValue = value as? Double {
                hue = doubleValue
            } else if let intValue = value as? Int {
                hue = Double(intValue)
            }
            updateColorCircle()
            (colorPickerView as? ColorWheelPickerView)?.updateColor(hue: hue, saturation: saturation)
        }

        if typeLower == "saturation" {
            if let doubleValue = value as? Double {
                saturation = doubleValue
            } else if let intValue = value as? Int {
                saturation = Double(intValue)
            }
            updateColorCircle()
            (colorPickerView as? ColorWheelPickerView)?.updateColor(hue: hue, saturation: saturation)
        }

        if typeLower == "colortemperature" {
            if let doubleValue = value as? Double {
                colorTemp = doubleValue
            } else if let intValue = value as? Int {
                colorTemp = Double(intValue)
            }
            updateColorCircle()
            (colorPickerView as? ColorTempPickerView)?.updateMired(colorTemp)
        }

        updateUI()
    }

    // MARK: - Private

    private func updateUI() {
        let actuallyOn = onCount > 0
        let allOn = onCount == accessoryCount
        let allOff = onCount == 0

        // Update icon based on group category and on/off state (same pattern as LightMenuItem)
        let iconName = PhosphorIcon.defaultIconName(for: groupCategory)
        if actuallyOn {
            iconView.image = PhosphorIcon.fill(iconName)
        } else {
            iconView.image = PhosphorIcon.regular(iconName)
        }

        // Use category-appropriate color
        let onColor: NSColor
        let categoryLower = groupCategory.lowercased()
        if categoryLower.contains("light") {
            onColor = DS.Colors.lightOn
        } else if categoryLower.contains("fan") {
            onColor = DS.Colors.fanOn
        } else if categoryLower.contains("lock") {
            onColor = actuallyOn ? DS.Colors.lockLocked : DS.Colors.lockUnlocked
        } else {
            onColor = DS.Colors.switchOn
        }
        iconView.contentTintColor = actuallyOn ? onColor : DS.Colors.iconForeground

        // Update toggle
        toggle.setOn(actuallyOn, animated: false)

        // Update slider state
        if hasBrightness {
            slider.isEnabled = isOn
        }

        // Show/hide slider - brightness slider needs isOn, position slider always visible
        let showSlider = hasPosition || (isOn && hasBrightness)
        slider.isHidden = !showSlider

        // Show/hide color circle
        let showColorCircle = isOn && hasColor
        colorCircle.isHidden = !showColorCircle

        // Collapse color picker if group turned off
        if !showColorCircle {
            isColorPickerExpanded = false
        }

        // Update frame height
        let newHeight = (isColorPickerExpanded && showColorCircle) ? expandedHeight : collapsedHeight
        if frame.height != newHeight {
            frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: newHeight)
            enclosingMenuItem?.menu?.itemChanged(enclosingMenuItem!)
        }

        colorControlsRow.isHidden = !(isColorPickerExpanded && showColorCircle)

        // Show "2/3" status only for partial state (itsyhome style)
        if !allOn && !allOff && accessoryCount > 1 {
            stateLabel.stringValue = "\(onCount)/\(accessoryCount)"
            stateLabel.textColor = DS.Colors.switchOn
            stateLabel.isHidden = false
        } else if hasPosition && !hasBrightness, let p = position {
            // Position groups (blinds) show percentage
            stateLabel.stringValue = "\(p)%"
            stateLabel.textColor = p > 0 ? DS.Colors.sliderBlind : DS.Colors.mutedForeground
            stateLabel.isHidden = false
        } else {
            stateLabel.isHidden = true
        }

        if showColorCircle {
            updateColorCircle()
        }

        layoutSubviews()
    }

    private func toggleColorPicker() {
        guard hasColor, isOn else { return }
        isColorPickerExpanded.toggle()
        updateUI()
    }

    private func updateColorCircle() {
        let color: NSColor
        if hasRGB {
            color = NSColor(hue: hue / 360.0, saturation: saturation / 100.0, brightness: 1.0, alpha: 1.0)
        } else if hasColorTemp {
            color = ColorConversion.miredToColor(colorTemp)
        } else {
            color = .white
        }
        colorCircle.layer?.backgroundColor = color.cgColor
    }

    @objc private func toggleChanged(_ sender: ToggleSwitch) {
        guard isReachable else { return }
        isOn = sender.isOn
        onCount = isOn ? accessoryCount : 0

        updateUI()
        setCharacteristic(type: "PowerState", value: isOn)
    }

    @objc private func sliderChanged(_ sender: ModernSlider) {
        guard isReachable else { return }
        let value = Int(sender.doubleValue)
        if hasBrightness {
            brightness = value
            setCharacteristic(type: "Brightness", value: value)
        } else if hasPosition {
            position = value
            setCharacteristic(type: "TargetPosition", value: value)
            // Update state label for position groups
            updateUI()
        }
    }

    private func handleRGBColorChange(hue newHue: Double, saturation newSat: Double, commit: Bool) {
        hue = newHue
        saturation = newSat
        updateColorCircle()
        if commit {
            setCharacteristic(type: "Hue", value: Float(newHue))
            setCharacteristic(type: "Saturation", value: Float(newSat))
        }
    }

    private func setColorTemp(_ mired: Double) {
        colorTemp = mired
        setCharacteristic(type: "ColorTemperature", value: Int(mired))
        updateColorCircle()
    }
}
