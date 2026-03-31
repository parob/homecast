//
//  LightMenuItem.swift
//  Homecast
//
//  Menu item for controlling lights with brightness slider and color picker
//

import AppKit

/// Menu item view for lights with brightness slider and expandable color picker
/// Layout (collapsed): [Icon] [Name] [ColorCircle?] [Slider] [Toggle]
/// Layout (expanded):  [Icon] [Name] [ColorCircle?] [Slider] [Toggle]
///                     [        Color Picker Row        ]
final class LightMenuItem: HighlightingMenuItemView {
    // MARK: - Properties

    private var isOn: Bool = false
    private var brightness: Double = 100
    private var hue: Double = 0
    private var saturation: Double = 100
    private var colorTemp: Double = 300
    private var colorTempMin: Double = 153
    private var colorTempMax: Double = 500

    private let hasBrightness: Bool
    private let hasRGB: Bool
    private let hasColorTemp: Bool
    private var hasColor: Bool { hasRGB || hasColorTemp }

    private let collapsedHeight: CGFloat = DS.ControlSize.menuItemHeight
    private var expandedHeight: CGFloat = DS.ControlSize.menuItemHeight
    private var isColorPickerExpanded: Bool = false

    // MARK: - UI Components

    private let toggle = ToggleSwitch()
    private let slider = ModernSlider()
    private let colorCircle = ClickableColorCircleView()
    private let colorControlsRow = NSView()
    private var colorPickerView: NSView?

    // MARK: - Initialization

    init(hasBrightness: Bool = true, hasRGB: Bool = false, hasColorTemp: Bool = false) {
        self.hasBrightness = hasBrightness
        self.hasRGB = hasRGB
        self.hasColorTemp = hasColorTemp
        super.init(frame: NSRect(x: 0, y: 0, width: DS.ControlSize.menuItemWidth, height: DS.ControlSize.menuItemHeight))
        setupViews()
    }

    override init(frame frameRect: NSRect) {
        self.hasBrightness = true
        self.hasRGB = false
        self.hasColorTemp = false
        super.init(frame: NSRect(x: 0, y: 0, width: DS.ControlSize.menuItemWidth, height: DS.ControlSize.menuItemHeight))
        setupViews()
    }

    required init?(coder: NSCoder) {
        self.hasBrightness = true
        self.hasRGB = false
        self.hasColorTemp = false
        super.init(coder: coder)
        setupViews()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    // MARK: - Setup

    private func setupViews() {
        // Toggle switch
        addSubview(toggle)
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))

        // Brightness slider
        slider.progressTintColor = DS.Colors.sliderLight
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = false
        slider.isHidden = true
        if hasBrightness {
            addSubview(slider)
        }

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

        // Don't close menu when clicking
        closesMenuOnAction = false
        onAction = { [weak self] in
            guard let self = self else { return }
            self.isOn.toggle()
            self.toggle.setOn(self.isOn, animated: true)
            let charType = self.configuration?.powerCharType ?? "PowerState"
            self.setCharacteristic(type: charType, value: self.isOn)
            self.updateUI()
        }

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
        if layoutUnreachable() { return }
        let height = frame.height
        let iconSize = DS.ControlSize.iconMedium
        let switchWidth = DS.ControlSize.switchWidth
        let switchHeight = DS.ControlSize.switchHeight
        let sliderWidth = DS.ControlSize.sliderWidth
        let colorCircleSize: CGFloat = 14

        let topRowY = height - collapsedHeight

        // Icon on left
        let iconY = topRowY + (collapsedHeight - iconSize) / 2
        iconView.frame = NSRect(x: DS.Spacing.menuItemPadding, y: iconY, width: iconSize, height: iconSize)

        // Toggle on right
        let switchX = frame.width - DS.Spacing.menuItemPadding - switchWidth
        let switchY = topRowY + (collapsedHeight - switchHeight) / 2
        toggle.frame = NSRect(x: switchX, y: switchY, width: switchWidth, height: switchHeight)

        // Slider before toggle (when on)
        let sliderX = switchX - sliderWidth - DS.Spacing.sm
        let sliderY = topRowY + (collapsedHeight - 12) / 2
        slider.frame = NSRect(x: sliderX, y: sliderY, width: sliderWidth, height: 12)

        // Color circle before slider
        let colorCircleX = sliderX - colorCircleSize - DS.Spacing.xs
        let colorCircleY = topRowY + (collapsedHeight - colorCircleSize) / 2
        colorCircle.frame = NSRect(x: colorCircleX, y: colorCircleY, width: colorCircleSize, height: colorCircleSize)

        // Name label fills remaining space
        let labelX = DS.Spacing.md + iconSize + DS.Spacing.sm
        var rightEdge = switchX - DS.Spacing.sm
        if !slider.isHidden {
            rightEdge = sliderX - DS.Spacing.xs
        }
        if !colorCircle.isHidden {
            rightEdge = colorCircleX - DS.Spacing.xs
        }
        let labelWidth = rightEdge - labelX
        nameLabel.frame = NSRect(x: labelX, y: topRowY + (collapsedHeight - 17) / 2, width: max(0, labelWidth), height: 17)

        // State label (hidden when slider visible)
        stateLabel.frame = NSRect(x: rightEdge - 35, y: topRowY + (collapsedHeight - 14) / 2, width: 35, height: 14)
    }

    // MARK: - Configuration

    override func configure(with config: MenuItemConfiguration) {
        super.configure(with: config)

        isOn = config.powerState ?? false
        brightness = Double(config.brightness ?? 100)
        hue = config.hue ?? 0
        saturation = config.saturation ?? 100
        colorTemp = config.colorTemperature ?? 300
        colorTempMin = config.colorTemperatureMin
        colorTempMax = config.colorTemperatureMax

        toggle.setOn(isOn, animated: false)
        toggle.isEnabled = isReachable

        slider.doubleValue = brightness
        slider.isEnabled = isReachable && isOn

        // Setup color picker if device supports color
        if hasColor && colorPickerView == nil {
            setupColorControlsRow()
        }

        if isReachable {
            updateUI()
        }
    }

    // MARK: - State Updates

    override func updateCharacteristic(_ type: String, value: Any) {
        let typeLower = type.lowercased().replacingOccurrences(of: "_", with: "")

        if typeLower == "powerstate" || typeLower == "on" {
            if let boolValue = value as? Bool {
                isOn = boolValue
            } else if let intValue = value as? Int {
                isOn = intValue != 0
            }
            toggle.setOn(isOn, animated: true)
            updateUI()
        }

        if typeLower == "brightness" {
            if let intValue = value as? Int {
                brightness = Double(intValue)
            } else if let doubleValue = value as? Double {
                brightness = doubleValue
            }
            slider.doubleValue = brightness
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
    }

    override func updateReachableAppearance() {
        super.updateReachableAppearance()

        toggle.isEnabled = isReachable
        toggle.isHidden = !isReachable
        slider.isEnabled = isReachable && isOn

        if !isReachable {
            slider.isHidden = true
            colorCircle.isHidden = true
            isColorPickerExpanded = false
            colorControlsRow.isHidden = true
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

    private func updateUI() {
        // Update icon based on on/off state and device category
        let iconCategory = configuration?.iconCategory.lowercased() ?? "light"
        let iconName = PhosphorIcon.defaultIconName(for: iconCategory)

        if isOn {
            iconView.image = PhosphorIcon.fill(iconName)
            iconView.contentTintColor = DS.Colors.lightOn
        } else {
            iconView.image = PhosphorIcon.regular(iconName)
            iconView.contentTintColor = DS.Colors.iconForeground
        }

        // Show/hide slider and color circle
        let showSlider = isOn && hasBrightness
        let showColorCircle = isOn && hasColor

        slider.isHidden = !showSlider
        slider.isEnabled = isReachable && isOn
        colorCircle.isHidden = !showColorCircle

        // Collapse color picker if light turned off
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

        // Update state label
        if isOn {
            stateLabel.isHidden = true
        } else {
            stateLabel.stringValue = "Off"
            stateLabel.textColor = DS.Colors.mutedForeground
            stateLabel.isHidden = false
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
        isOn = sender.isOn
        let charType = configuration?.powerCharType ?? "PowerState"
        setCharacteristic(type: charType, value: isOn)
        updateUI()
    }

    @objc private func sliderChanged(_ sender: ModernSlider) {
        let value = sender.doubleValue
        brightness = value
        setCharacteristic(type: "Brightness", value: Int(value))

        // If brightness > 0 and light is off, turn it on
        if value > 0 && !isOn {
            isOn = true
            toggle.setOn(true, animated: true)
            let charType = configuration?.powerCharType ?? "PowerState"
            setCharacteristic(type: charType, value: true)
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
