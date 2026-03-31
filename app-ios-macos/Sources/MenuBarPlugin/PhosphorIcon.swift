//
//  PhosphorIcon.swift
//  Homecast
//
//  Phosphor Icons integration for consistent iconography
//  Icons are loaded at runtime from SVG files: ph.{name}.svg and ph.{name}.fill.svg
//

import AppKit

// MARK: - PhosphorIcon

enum PhosphorIcon {

    /// The bundle containing Phosphor icon SVGs
    private static let bundle = Bundle.main

    /// Cache for loaded icons to avoid repeated disk reads
    private static var iconCache: [String: NSImage] = [:]
    private static let cacheLock = NSLock()

    /// Get a Phosphor icon by name (regular weight)
    static func regular(_ name: String) -> NSImage? {
        loadIcon(named: "ph.\(name)")
    }

    /// Get a Phosphor icon by name (fill weight)
    static func fill(_ name: String) -> NSImage? {
        loadIcon(named: "ph.\(name).fill")
    }

    /// Get icon with automatic variant based on state (fill when on, regular when off)
    static func icon(_ name: String, filled: Bool) -> NSImage? {
        filled ? fill(name) : regular(name)
    }

    /// Load an icon from the bundle's Resources/PhosphorIcons folder (PDF format)
    /// Falls back to SF Symbols if Phosphor icon not found
    private static func loadIcon(named name: String) -> NSImage? {
        // Check cache first
        cacheLock.lock()
        if let cached = iconCache[name] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var image: NSImage?

        // Try loading PDF from bundle (Phosphor icons)
        if let url = bundle.url(forResource: name, withExtension: "pdf", subdirectory: "PhosphorIcons"),
           let loadedImage = NSImage(contentsOf: url) {
            loadedImage.isTemplate = true
            image = loadedImage
        }

        // Fall back to SF Symbol if Phosphor icon not found
        if image == nil {
            // Extract icon name from "ph.name" or "ph.name.fill" format
            let iconName = name
                .replacingOccurrences(of: "ph.", with: "")
                .replacingOccurrences(of: ".fill", with: "")
            let isFill = name.hasSuffix(".fill")

            if let sfSymbol = sfSymbolFallback(for: iconName, fill: isFill) {
                image = sfSymbol
            }
        }

        // Cache the result (even if nil to avoid repeated lookups)
        if let image = image {
            cacheLock.lock()
            iconCache[name] = image
            cacheLock.unlock()
        }

        return image
    }

    /// SF Symbol fallback mapping for when Phosphor icons are not bundled
    private static func sfSymbolFallback(for name: String, fill: Bool) -> NSImage? {
        let sfName: String?

        switch name {
        // Device icons
        case "lightbulb", "lightbulb-filament":
            sfName = fill ? "lightbulb.fill" : "lightbulb"
        case "power":
            sfName = "power"
        case "plug", "plug-charging", "plugs":
            sfName = fill ? "powerplug.fill" : "powerplug"
        case "thermometer", "thermometer-simple", "thermometer-cold", "thermometer-hot":
            sfName = fill ? "thermometer.medium" : "thermometer"
        case "lock":
            sfName = fill ? "lock.fill" : "lock"
        case "lock-open":
            sfName = fill ? "lock.open.fill" : "lock.open"
        case "fan":
            sfName = "fan.fill"
        case "garage":
            sfName = fill ? "car.garage.fill" : "car.garage"
        case "arrows-out-line-vertical", "caret-up-down":
            sfName = "arrow.up.and.down"
        case "door", "door-open":
            sfName = fill ? "door.left.hand.closed" : "door.left.hand.open"
        case "fire", "fire-simple":
            sfName = fill ? "flame.fill" : "flame"
        case "snowflake":
            sfName = "snowflake"
        case "arrows-left-right":
            sfName = "arrow.left.arrow.right"
        case "drop", "drop-simple":
            sfName = fill ? "drop.fill" : "drop"
        case "drop-half", "drop-half-bottom":
            sfName = "humidity.fill"
        case "wind":
            sfName = "wind"
        case "pipe":
            sfName = "drop.fill"
        case "shield", "shield-check", "shield-star", "shield-warning":
            sfName = fill ? "shield.fill" : "shield"
        case "speaker-high", "speaker-low":
            sfName = fill ? "speaker.wave.3.fill" : "speaker.wave.3"
        case "video-camera", "camera":
            sfName = fill ? "video.fill" : "video"
        case "battery-low", "battery-warning":
            sfName = "battery.25percent"
        case "broadcast":
            sfName = "antenna.radiowaves.left.and.right"
        case "circle":
            sfName = fill ? "circle.fill" : "circle"
        case "warning":
            sfName = fill ? "exclamationmark.triangle.fill" : "exclamationmark.triangle"

        // Room icons
        case "couch":
            sfName = fill ? "sofa.fill" : "sofa"
        case "bed":
            sfName = fill ? "bed.double.fill" : "bed.double"
        case "cooking-pot":
            sfName = fill ? "frying.pan.fill" : "frying.pan"
        case "fork-knife":
            sfName = "fork.knife"
        case "bathtub":
            sfName = fill ? "bathtub.fill" : "bathtub"
        case "shower":
            sfName = "shower.fill"
        case "desktop":
            sfName = fill ? "desktopcomputer" : "desktopcomputer"
        case "books":
            sfName = fill ? "books.vertical.fill" : "books.vertical"
        case "washing-machine":
            sfName = fill ? "washer.fill" : "washer"
        case "coat-hanger":
            sfName = "tshirt.fill"
        case "archive-box":
            sfName = fill ? "archivebox.fill" : "archivebox"
        case "tree":
            sfName = fill ? "tree.fill" : "tree"
        case "sun-horizon":
            sfName = fill ? "sun.horizon.fill" : "sun.horizon"
        case "swimming-pool":
            sfName = "figure.pool.swim"
        case "plant":
            sfName = fill ? "leaf.fill" : "leaf"
        case "stairs":
            sfName = "stairs"
        case "house", "house-line":
            sfName = fill ? "house.fill" : "house"
        case "baby":
            sfName = "figure.and.child.holdinghands"
        case "barbell":
            sfName = "dumbbell.fill"
        case "user":
            sfName = fill ? "person.fill" : "person"
        case "film-strip":
            sfName = "film"
        case "game-controller":
            sfName = fill ? "gamecontroller.fill" : "gamecontroller"
        case "remote-control":
            sfName = fill ? "appletvremote.gen1.fill" : "appletvremote.gen1"
        case "wine":
            sfName = "wineglass.fill"
        case "palette":
            sfName = fill ? "paintpalette.fill" : "paintpalette"
        case "paw-print":
            sfName = fill ? "pawprint.fill" : "pawprint"
        case "hard-drives":
            sfName = fill ? "externaldrive.fill" : "externaldrive"

        // Scene icons
        case "moon", "moon-stars":
            sfName = fill ? "moon.fill" : "moon"
        case "sun":
            sfName = fill ? "sun.max.fill" : "sun.max"
        case "confetti":
            sfName = "party.popper.fill"
        case "coffee":
            sfName = fill ? "cup.and.saucer.fill" : "cup.and.saucer"
        case "briefcase":
            sfName = fill ? "briefcase.fill" : "briefcase"
        case "airplane-takeoff":
            sfName = "airplane.departure"
        case "book-open":
            sfName = fill ? "book.fill" : "book"
        case "heart":
            sfName = fill ? "heart.fill" : "heart"
        case "music-notes":
            sfName = fill ? "music.note" : "music.note"
        case "sparkle":
            sfName = "sparkles"
        case "television":
            sfName = fill ? "tv.fill" : "tv"

        // UI icons
        case "star":
            sfName = fill ? "star.fill" : "star"
        case "eye":
            sfName = fill ? "eye.fill" : "eye"
        case "eye-slash":
            sfName = fill ? "eye.slash.fill" : "eye.slash"
        case "push-pin":
            sfName = fill ? "pin.fill" : "pin"
        case "pencil-simple":
            sfName = "pencil"
        case "trash":
            sfName = fill ? "trash.fill" : "trash"
        case "plus":
            sfName = "plus"
        case "minus":
            sfName = "minus"
        case "gear":
            sfName = fill ? "gearshape.fill" : "gearshape"
        case "caret-right":
            sfName = "chevron.right"
        case "caret-down":
            sfName = "chevron.down"
        case "caret-up":
            sfName = "chevron.up"
        case "dots-six-vertical":
            sfName = "line.3.horizontal"
        case "x":
            sfName = "xmark"
        case "check":
            sfName = "checkmark"
        case "info":
            sfName = fill ? "info.circle.fill" : "info.circle"
        case "question":
            sfName = fill ? "questionmark.circle.fill" : "questionmark.circle"
        case "arrows-clockwise":
            sfName = "arrow.clockwise"
        case "keyboard":
            sfName = fill ? "keyboard.fill" : "keyboard"
        case "cloud":
            sfName = fill ? "cloud.fill" : "cloud"
        case "cloud-check":
            sfName = "checkmark.icloud.fill"
        case "bell", "bell-ringing":
            sfName = fill ? "bell.fill" : "bell"
        case "copy":
            sfName = fill ? "doc.on.doc.fill" : "doc.on.doc"
        case "link":
            sfName = "link"

        // Group icons
        case "squares-four", "grid-four":
            sfName = fill ? "square.grid.2x2.fill" : "square.grid.2x2"
        case "stack":
            sfName = fill ? "square.stack.fill" : "square.stack"
        case "folder":
            sfName = fill ? "folder.fill" : "folder"
        case "tag":
            sfName = fill ? "tag.fill" : "tag"

        // Action icons
        case "stop-circle":
            sfName = fill ? "stop.circle.fill" : "stop.circle"
        case "person-simple-walk":
            sfName = "figure.walk"
        case "activity":
            sfName = "waveform.path.ecg"
        case "lamp", "lamp-pendant":
            sfName = "lamp.ceiling.fill"
        case "headlights":
            sfName = "headlight.high.beam.fill"
        case "toggle-left", "toggle-right":
            sfName = "switch.2"
        case "browser", "frame-corners":
            sfName = "square.split.2x2"
        case "rows", "equals", "list":
            sfName = "line.3.horizontal"
        case "key", "keyhole":
            sfName = fill ? "key.fill" : "key"
        case "lock-key", "lock-simple", "lock-laminated":
            sfName = fill ? "lock.fill" : "lock"
        case "scan":
            sfName = "viewfinder"
        case "car", "car-profile", "car-simple":
            sfName = fill ? "car.fill" : "car"

        default:
            sfName = nil
        }

        guard let symbolName = sfName else { return nil }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    /// Preload commonly used icons for better performance
    static func preloadCommonIcons() {
        let commonIcons = [
            "lightbulb", "power", "thermometer", "lock", "fan", "garage",
            "house", "gear", "star", "caret-right", "caret-down", "x"
        ]
        for name in commonIcons {
            _ = regular(name)
            _ = fill(name)
        }
    }

    /// Get all available icon names (excluding fill variants)
    static func allIconNames() -> [String] {
        guard let resourcePath = bundle.resourcePath else { return [] }
        let phosphorPath = (resourcePath as NSString).appendingPathComponent("PhosphorIcons")

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: phosphorPath)
            var names: Set<String> = []
            for file in files where file.hasPrefix("ph.") && file.hasSuffix(".svg") && !file.contains(".fill.") {
                // Extract name: "ph.name.svg" -> "name"
                let name = String(file.dropFirst(3).dropLast(4))
                names.insert(name)
            }
            return names.sorted()
        } catch {
            return []
        }
    }
}

// MARK: - Accessory type icon definitions

extension PhosphorIcon {

    /// Icon configuration for an accessory type
    struct AccessoryIconConfig {
        let defaultIcon: String
        let suggestedIcons: [String]
        /// Mode-specific icons (e.g., heat/cool/auto for AC, locked/unlocked for locks)
        let modeIcons: [String: String]

        init(defaultIcon: String, suggestedIcons: [String], modeIcons: [String: String] = [:]) {
            self.defaultIcon = defaultIcon
            self.suggestedIcons = suggestedIcons
            self.modeIcons = modeIcons
        }
    }

    /// Get mode icon name for a service type and mode
    static func modeIconName(for serviceType: String, mode: String) -> String? {
        accessoryIconConfigs[serviceType]?.modeIcons[mode]
    }

    /// Get mode icon for a service type and mode
    static func modeIcon(for serviceType: String, mode: String, filled: Bool = true) -> NSImage? {
        guard let iconName = modeIconName(for: serviceType, mode: mode) else { return nil }
        return icon(iconName, filled: filled)
    }

    /// Get the default icon for a service type
    static func defaultIcon(for serviceType: String) -> NSImage? {
        guard let config = accessoryIconConfigs[serviceType] else {
            return regular("question")
        }
        return regular(config.defaultIcon)
    }

    /// Get the default icon name for a service type (case-insensitive)
    /// Uses the same matching logic as control selection in MenuBarPlugin
    static func defaultIconName(for serviceType: String) -> String {
        let normalized = serviceType.lowercased()

        // Check direct match first
        if let config = accessoryIconConfigs[normalized] {
            return config.defaultIcon
        }

        // Use same contains-based matching as MenuBarPlugin.createMenuItemView()
        // This ensures icon selection matches control selection
        if normalized.contains("light") || normalized.contains("bulb") || normalized.contains("lamp") {
            return "lightbulb"
        }
        if normalized.contains("thermostat") || normalized.contains("heater") || normalized.contains("cooler") {
            return "thermometer"
        }
        if normalized.contains("window") && normalized.contains("covering") {
            return "arrows-out-line-vertical"
        }
        if normalized.contains("lock") {
            return "lock"
        }
        if normalized.contains("garage") {
            return "garage"
        }
        if normalized.contains("fan") {
            return "fan"
        }
        if normalized.contains("switch") || normalized.contains("outlet") {
            return "power"
        }
        if normalized.contains("contact") {
            return "door-open"
        }
        if normalized.contains("motion") {
            return "person-simple-walk"
        }
        if normalized.contains("occupancy") {
            return "user"
        }
        if normalized.contains("humidity") {
            return "drop-half"
        }
        if normalized.contains("sensor") {
            return "thermometer"
        }
        if normalized.contains("camera") || normalized.contains("video") {
            return "video-camera"
        }
        if normalized.contains("doorbell") {
            return "bell"
        }
        if normalized.contains("bridge") {
            return "broadcast"
        }
        if normalized.contains("button") || normalized.contains("programmable") {
            return "remote-control"
        }
        if normalized.contains("remote") {
            return "remote-control"
        }
        if normalized == "info" {
            return "broadcast"
        }
        if normalized.contains("smoke") || normalized.contains("alarm") {
            return "shield-check"
        }

        return "question"
    }

    /// Get suggested icons for a service type (for icon picker)
    static func suggestedIcons(for serviceType: String) -> [String] {
        accessoryIconConfigs[serviceType]?.suggestedIcons ?? []
    }

    /// Icon configurations for all accessory types (using friendly names from CharacteristicMapper)
    static let accessoryIconConfigs: [String: AccessoryIconConfig] = [
        // Lights (including common aliases)
        "lightbulb": AccessoryIconConfig(
            defaultIcon: "lightbulb",
            suggestedIcons: ["lightbulb", "lightbulb-filament", "sun", "lamp", "lamp-pendant", "headlights"]
        ),
        "light": AccessoryIconConfig(
            defaultIcon: "lightbulb",
            suggestedIcons: ["lightbulb", "lightbulb-filament", "sun", "lamp", "lamp-pendant", "headlights"]
        ),
        "lighting": AccessoryIconConfig(
            defaultIcon: "lightbulb",
            suggestedIcons: ["lightbulb", "lightbulb-filament", "sun", "lamp", "lamp-pendant", "headlights"]
        ),

        // Switches & Outlets
        "switch": AccessoryIconConfig(
            defaultIcon: "power",
            suggestedIcons: ["power", "toggle-left", "toggle-right", "plug", "plug-charging", "plugs"]
        ),
        "outlet": AccessoryIconConfig(
            defaultIcon: "plug",
            suggestedIcons: ["plug", "plug-charging", "plugs", "power", "toggle-left", "toggle-right"]
        ),

        // Thermostats
        "thermostat": AccessoryIconConfig(
            defaultIcon: "thermometer",
            suggestedIcons: ["thermometer", "thermometer-cold", "thermometer-hot", "thermometer-simple"],
            modeIcons: ["heat": "fire", "cool": "snowflake", "auto": "arrows-left-right"]
        ),

        // Heater/Cooler (AC)
        "heater_cooler": AccessoryIconConfig(
            defaultIcon: "thermometer-simple",
            suggestedIcons: ["snowflake", "thermometer", "fire", "fire-simple", "thermometer-cold", "thermometer-hot", "thermometer-simple"],
            modeIcons: ["heat": "fire", "cool": "snowflake", "auto": "arrows-left-right"]
        ),

        // Door Locks
        "lock": AccessoryIconConfig(
            defaultIcon: "lock",
            suggestedIcons: ["lock", "lock-key", "lock-simple", "lock-laminated", "keyhole", "key"],
            modeIcons: ["locked": "lock", "unlocked": "lock-open"]
        ),

        // Fans
        "fan": AccessoryIconConfig(
            defaultIcon: "fan",
            suggestedIcons: ["fan", "wind"]
        ),

        // Window Coverings / Blinds
        "window_covering": AccessoryIconConfig(
            defaultIcon: "arrows-out-line-vertical",
            suggestedIcons: ["arrows-out-line-vertical", "caret-up-down", "list"]
        ),

        // Doors (motorized)
        "door": AccessoryIconConfig(
            defaultIcon: "door-open",
            suggestedIcons: ["door-open", "door", "arrows-out-line-vertical"]
        ),

        // Windows (motorized)
        "window": AccessoryIconConfig(
            defaultIcon: "browser",
            suggestedIcons: ["browser", "frame-corners", "arrows-out-line-vertical"]
        ),

        // Garage Doors
        "garage_door": AccessoryIconConfig(
            defaultIcon: "garage",
            suggestedIcons: ["garage", "car", "car-profile", "car-simple"],
            modeIcons: ["open": "garage", "closed": "garage", "obstructed": "warning"]
        ),

        // Humidifiers
        "humidifier_dehumidifier": AccessoryIconConfig(
            defaultIcon: "drop-half",
            suggestedIcons: ["drop-half", "drop", "drop-simple", "drop-half-bottom"],
            modeIcons: ["humidify": "drop-half", "dehumidify": "drop"]
        ),

        // Air Purifiers
        "air_purifier": AccessoryIconConfig(
            defaultIcon: "wind",
            suggestedIcons: ["wind", "fan"]
        ),

        // Valves
        "valve": AccessoryIconConfig(
            defaultIcon: "pipe",
            suggestedIcons: ["pipe", "shower", "drop"]
        ),

        // Faucets
        "faucet": AccessoryIconConfig(
            defaultIcon: "drop",
            suggestedIcons: ["drop", "drop-half", "pipe", "shower"]
        ),

        // Slats
        "slats": AccessoryIconConfig(
            defaultIcon: "list",
            suggestedIcons: ["list", "equals", "rows", "caret-up-down"]
        ),

        // Security Systems
        "security_system": AccessoryIconConfig(
            defaultIcon: "shield",
            suggestedIcons: ["shield", "shield-check", "shield-star", "key", "lock"],
            modeIcons: ["disarmed": "shield", "armed": "shield-check", "triggered": "shield-warning"]
        ),

        // Temperature Sensors
        "temperature_sensor": AccessoryIconConfig(
            defaultIcon: "thermometer",
            suggestedIcons: ["thermometer", "thermometer-cold", "thermometer-hot", "thermometer-simple"]
        ),

        // Humidity Sensors
        "humidity_sensor": AccessoryIconConfig(
            defaultIcon: "drop-half",
            suggestedIcons: ["drop", "drop-simple", "drop-half", "drop-half-bottom"]
        ),

        // Motion Sensors
        "motion_sensor": AccessoryIconConfig(
            defaultIcon: "person-simple-walk",
            suggestedIcons: ["person-simple-walk", "eye", "scan"]
        ),

        // Contact Sensors
        "contact_sensor": AccessoryIconConfig(
            defaultIcon: "door-open",
            suggestedIcons: ["door-open", "door", "frame-corners"]
        ),

        // Speakers
        "speaker": AccessoryIconConfig(
            defaultIcon: "speaker-high",
            suggestedIcons: ["speaker-high", "speaker-low", "music-notes"]
        ),

        // Cameras
        "camera_rtp_stream_management": AccessoryIconConfig(
            defaultIcon: "video-camera",
            suggestedIcons: ["video-camera", "camera", "eye"]
        ),

        // Camera (JS-resolved widget type)
        "camera": AccessoryIconConfig(
            defaultIcon: "video-camera",
            suggestedIcons: ["video-camera", "camera", "eye"]
        ),

        // Doorbell
        "doorbell": AccessoryIconConfig(
            defaultIcon: "bell",
            suggestedIcons: ["bell", "bell-ringing", "video-camera"]
        ),

        // Info / Bridge devices
        "info": AccessoryIconConfig(
            defaultIcon: "broadcast",
            suggestedIcons: ["broadcast", "hard-drives", "cloud"]
        ),

        // Remote (multi-button programmable switches)
        "remote": AccessoryIconConfig(
            defaultIcon: "remote-control",
            suggestedIcons: ["remote-control", "game-controller", "keyboard"]
        ),

        // Button (single-button programmable switches)
        "button": AccessoryIconConfig(
            defaultIcon: "remote-control",
            suggestedIcons: ["remote-control", "circle", "keyboard"]
        ),

        // Smoke / CO alarm
        "smoke_alarm": AccessoryIconConfig(
            defaultIcon: "shield-check",
            suggestedIcons: ["shield-check", "shield-warning", "warning"]
        ),

        // Door / Window
        "door_window": AccessoryIconConfig(
            defaultIcon: "door-open",
            suggestedIcons: ["door-open", "door", "frame-corners"]
        ),

        // Multi-sensor
        "multi_sensor": AccessoryIconConfig(
            defaultIcon: "activity",
            suggestedIcons: ["activity", "thermometer", "person-simple-walk"]
        ),
    ]
}

// MARK: - Room icon mappings

extension PhosphorIcon {

    /// Get icon for a room based on its name
    static func iconForRoom(_ name: String) -> NSImage? {
        regular(iconNameForRoom(name))
    }

    /// Get icon name for a room based on its name
    static func iconNameForRoom(_ name: String) -> String {
        let lowercased = name.lowercased()

        // Living spaces
        if lowercased.contains("living") || lowercased.contains("lounge") || lowercased.contains("family") || lowercased.contains("den") {
            return "couch"
        }
        // Bedrooms
        if lowercased.contains("bedroom") || lowercased.contains("bed") {
            return "bed"
        }
        // Kitchen
        if lowercased.contains("kitchen") || lowercased.contains("kitchenette") {
            return "cooking-pot"
        }
        // Dining
        if lowercased.contains("dining") || lowercased.contains("breakfast") {
            return "fork-knife"
        }
        // Bathrooms
        if lowercased.contains("bath") || lowercased.contains("restroom") || lowercased.contains("toilet") || lowercased.contains("powder") {
            return "bathtub"
        }
        if lowercased.contains("shower") {
            return "shower"
        }
        // Work spaces
        if lowercased.contains("office") || lowercased.contains("study") || lowercased.contains("workspace") {
            return "desktop"
        }
        if lowercased.contains("library") || lowercased.contains("reading") {
            return "books"
        }
        // Utility
        if lowercased.contains("laundry") || lowercased.contains("utility") || lowercased.contains("mud room") || lowercased.contains("mudroom") {
            return "washing-machine"
        }
        if lowercased.contains("closet") || lowercased.contains("wardrobe") || lowercased.contains("dressing") {
            return "coat-hanger"
        }
        if lowercased.contains("storage") || lowercased.contains("store room") {
            return "archive-box"
        }
        // Garage & outdoor
        if lowercased.contains("garage") || lowercased.contains("carport") {
            return "garage"
        }
        if lowercased.contains("garden") || lowercased.contains("yard") || lowercased.contains("outdoor") || lowercased.contains("outside") {
            return "tree"
        }
        if lowercased.contains("balcony") || lowercased.contains("patio") || lowercased.contains("terrace") || lowercased.contains("deck") || lowercased.contains("porch") {
            return "sun-horizon"
        }
        if lowercased.contains("pool") || lowercased.contains("swimming") {
            return "swimming-pool"
        }
        if lowercased.contains("greenhouse") || lowercased.contains("conservatory") {
            return "plant"
        }
        // Entries & passages
        if lowercased.contains("hallway") || lowercased.contains("hall") || lowercased.contains("corridor") || lowercased.contains("passage") || lowercased.contains("landing") {
            return "door-open"
        }
        if lowercased.contains("entry") || lowercased.contains("foyer") || lowercased.contains("vestibule") || lowercased.contains("entrance") || lowercased.contains("lobby") {
            return "door"
        }
        if lowercased.contains("stairs") || lowercased.contains("stairway") || lowercased.contains("staircase") {
            return "stairs"
        }
        // Levels
        if lowercased.contains("basement") || lowercased.contains("cellar") || lowercased.contains("lower level") {
            return "stairs"
        }
        if lowercased.contains("attic") || lowercased.contains("loft") || lowercased.contains("upper level") {
            return "house-line"
        }
        // Kids & wellness
        if lowercased.contains("nursery") || lowercased.contains("kid") || lowercased.contains("child") || lowercased.contains("playroom") {
            return "baby"
        }
        if lowercased.contains("gym") || lowercased.contains("fitness") || lowercased.contains("workout") || lowercased.contains("exercise") {
            return "barbell"
        }
        if lowercased.contains("spa") || lowercased.contains("sauna") || lowercased.contains("steam") {
            return "drop"
        }
        // Guest & misc
        if lowercased.contains("guest") || lowercased.contains("spare") {
            return "user"
        }
        if lowercased.contains("theater") || lowercased.contains("theatre") || lowercased.contains("cinema") || lowercased.contains("movie") {
            return "film-strip"
        }
        if lowercased.contains("game") || lowercased.contains("gaming") || lowercased.contains("rec room") || lowercased.contains("recreation") {
            return "game-controller"
        }
        if lowercased.contains("wine") || lowercased.contains("cellar") {
            return "wine"
        }
        if lowercased.contains("studio") || lowercased.contains("art") || lowercased.contains("craft") {
            return "palette"
        }
        if lowercased.contains("pet") || lowercased.contains("dog") || lowercased.contains("cat") {
            return "paw-print"
        }
        if lowercased.contains("server") || lowercased.contains("network") || lowercased.contains("tech") {
            return "hard-drives"
        }

        return "door"
    }

    /// Suggested room icons for picker
    static let suggestedRoomIcons: [String] = [
        "house", "couch", "bed", "cooking-pot", "bathtub", "desktop",
        "garage", "tree", "fork-knife", "door-open", "washing-machine",
        "stairs", "house-line", "sun-horizon", "swimming-pool", "barbell",
        "baby", "user", "television", "game-controller"
    ]
}

// MARK: - Scene icons

extension PhosphorIcon {

    /// Infer a scene icon based on its name
    static func iconForScene(_ name: String) -> NSImage? {
        regular(iconNameForScene(name))
    }

    /// Infer a scene icon name based on its name
    static func iconNameForScene(_ name: String) -> String {
        let lowercased = name.lowercased()

        if lowercased.contains("morning") || lowercased.contains("sunrise") || lowercased.contains("wake") {
            return "sun-horizon"
        } else if lowercased.contains("night") || lowercased.contains("sleep") || lowercased.contains("bedtime") {
            return "moon"
        } else if lowercased.contains("movie") || lowercased.contains("cinema") || lowercased.contains("theater") {
            return "film-strip"
        } else if lowercased.contains("party") || lowercased.contains("celebration") {
            return "confetti"
        } else if lowercased.contains("relax") || lowercased.contains("chill") || lowercased.contains("calm") {
            return "coffee"
        } else if lowercased.contains("work") || lowercased.contains("focus") || lowercased.contains("office") {
            return "briefcase"
        } else if lowercased.contains("dinner") || lowercased.contains("meal") || lowercased.contains("eat") {
            return "fork-knife"
        } else if lowercased.contains("away") || lowercased.contains("leave") || lowercased.contains("goodbye") || lowercased.contains("vacation") {
            return "airplane-takeoff"
        } else if lowercased.contains("home") || lowercased.contains("arrive") || lowercased.contains("welcome") {
            return "house"
        } else if lowercased.contains("bright") || lowercased.contains("full") {
            return "sun"
        } else if lowercased.contains("dim") || lowercased.contains("low") {
            return "moon-stars"
        } else if lowercased.contains("off") || lowercased.contains("all off") {
            return "power"
        } else if lowercased.contains("on") || lowercased.contains("all on") {
            return "lightbulb"
        } else if lowercased.contains("reading") {
            return "book-open"
        } else if lowercased.contains("romantic") || lowercased.contains("date") {
            return "heart"
        } else if lowercased.contains("gaming") || lowercased.contains("game") {
            return "game-controller"
        } else if lowercased.contains("music") || lowercased.contains("listen") {
            return "music-notes"
        } else {
            return "sparkle"
        }
    }

    /// Suggested scene icons for picker
    static let suggestedSceneIcons: [String] = [
        "sparkle", "sun-horizon", "moon", "sun", "moon-stars", "lightbulb",
        "power", "house", "airplane-takeoff", "film-strip", "confetti",
        "coffee", "briefcase", "fork-knife", "book-open", "heart",
        "game-controller", "music-notes", "television", "bed"
    ]
}

// MARK: - Group icons

extension PhosphorIcon {

    /// Default icon for groups
    static let defaultGroupIcon = "squares-four"

    /// Suggested group icons for picker
    static let suggestedGroupIcons: [String] = [
        "squares-four", "grid-four", "stack", "folder", "tag",
        "lightbulb", "lamp", "fan", "thermometer", "lock",
        "house", "couch", "bed", "sun", "moon"
    ]
}

// MARK: - Mode icons (for AC, thermostat, etc.)

extension PhosphorIcon {

    enum ACMode: Int {
        case auto = 0
        case heat = 1
        case cool = 2
    }

    static func iconForACMode(_ mode: ACMode) -> NSImage? {
        switch mode {
        case .auto:
            return regular("arrows-left-right")
        case .heat:
            return regular("fire")
        case .cool:
            return regular("snowflake")
        }
    }

    static func iconNameForACMode(_ mode: ACMode) -> String {
        switch mode {
        case .auto:
            return "arrows-left-right"
        case .heat:
            return "fire"
        case .cool:
            return "snowflake"
        }
    }
}

// MARK: - Lock state icons

extension PhosphorIcon {

    enum LockState: Int {
        case unlocked = 0
        case locked = 1
        case jammed = 2
        case unknown = 3
    }

    static func iconForLockState(_ state: LockState) -> NSImage? {
        switch state {
        case .locked:
            return fill("lock")
        case .unlocked:
            return regular("lock-open")
        case .jammed:
            return regular("warning")
        case .unknown:
            return regular("lock")
        }
    }
}

// MARK: - Garage door state icons

extension PhosphorIcon {

    enum GarageDoorState: Int {
        case open = 0
        case closed = 1
        case opening = 2
        case closing = 3
        case stopped = 4
    }

    static func iconForGarageDoorState(_ state: GarageDoorState) -> NSImage? {
        switch state {
        case .open, .opening, .stopped:
            return regular("garage")
        case .closed, .closing:
            return fill("garage")
        }
    }
}

// MARK: - Security system state icons

extension PhosphorIcon {

    enum SecurityState: Int {
        case stayArm = 0
        case awayArm = 1
        case nightArm = 2
        case disarmed = 3
        case triggered = 4
    }

    static func iconForSecurityState(_ state: SecurityState) -> NSImage? {
        switch state {
        case .stayArm:
            return fill("shield-check")
        case .awayArm:
            return fill("shield-check")
        case .nightArm:
            return regular("moon")
        case .disarmed:
            return regular("shield")
        case .triggered:
            return fill("shield-warning")
        }
    }

    static func iconNameForSecurityState(_ state: SecurityState) -> String {
        switch state {
        case .stayArm, .awayArm:
            return "shield-check"
        case .nightArm:
            return "moon"
        case .disarmed:
            return "shield"
        case .triggered:
            return "shield-warning"
        }
    }
}

// MARK: - UI icons (for buttons, settings, etc.)

extension PhosphorIcon {

    // Common UI icons used throughout the app
    static var star: NSImage? { regular("star") }
    static var starFill: NSImage? { fill("star") }
    static var eye: NSImage? { regular("eye") }
    static var eyeSlash: NSImage? { regular("eye-slash") }
    static var pin: NSImage? { regular("push-pin") }
    static var pinFill: NSImage? { fill("push-pin") }
    static var pencil: NSImage? { regular("pencil-simple") }
    static var trash: NSImage? { regular("trash") }
    static var plus: NSImage? { regular("plus") }
    static var minus: NSImage? { regular("minus") }
    static var gear: NSImage? { regular("gear") }
    static var chevronRight: NSImage? { regular("caret-right") }
    static var chevronDown: NSImage? { regular("caret-down") }
    static var chevronUp: NSImage? { regular("caret-up") }
    static var dragHandle: NSImage? { regular("dots-six-vertical") }
    static var close: NSImage? { regular("x") }
    static var check: NSImage? { regular("check") }
    static var warning: NSImage? { regular("warning") }
    static var info: NSImage? { regular("info") }
    static var question: NSImage? { regular("question") }
    static var refresh: NSImage? { regular("arrows-clockwise") }
    static var keyboard: NSImage? { regular("keyboard") }
    static var cloud: NSImage? { regular("cloud") }
    static var cloudCheck: NSImage? { regular("cloud-check") }
    static var bell: NSImage? { regular("bell") }
    static var bellRinging: NSImage? { regular("bell-ringing") }
    static var copy: NSImage? { regular("copy") }
    static var link: NSImage? { regular("link") }
    static var sparkle: NSImage? { regular("sparkle") }
}
