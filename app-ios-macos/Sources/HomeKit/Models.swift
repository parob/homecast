import HomeKit
import Foundation
import CoreFoundation
import CoreLocation

// MARK: - JSON Value Type

/// A type-safe representation of JSON values for serialization
enum JSONValue {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Convert to a Foundation object suitable for JSONSerialization
    func toFoundation() -> Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let arr): return arr.map { $0.toFoundation() }
        case .object(let obj): return obj.mapValues { $0.toFoundation() }
        case .null: return NSNull()
        }
    }

    /// Create a JSONValue from any Foundation type
    static func from(_ value: Any) -> JSONValue {
        switch value {
        case let s as String:
            return .string(s)
        case let i as Int:
            return .int(i)
        case let d as Double:
            return .double(d)
        case let b as Bool:
            return .bool(b)
        case let arr as [Any]:
            return .array(arr.map { JSONValue.from($0) })
        case let dict as [String: Any]:
            return .object(dict.mapValues { JSONValue.from($0) })
        case is NSNull:
            return .null
        default:
            return .string(String(describing: value))
        }
    }
}

// MARK: - Home Model

struct HomeModel: Codable {
    let id: String
    let name: String
    let isPrimary: Bool
    let roomCount: Int
    let accessoryCount: Int

    init(from home: HMHome) {
        self.id = home.uniqueIdentifier.uuidString
        self.name = home.name
        self.isPrimary = home.isPrimary
        self.roomCount = home.rooms.count
        self.accessoryCount = home.accessories.count
    }

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "isPrimary": .bool(isPrimary),
            "roomCount": .int(roomCount),
            "accessoryCount": .int(accessoryCount)
        ])
    }
}

// MARK: - Room Model

struct RoomModel: Codable {
    let id: String
    let name: String
    let accessoryCount: Int

    init(from room: HMRoom) {
        self.id = room.uniqueIdentifier.uuidString
        self.name = room.name
        self.accessoryCount = room.accessories.count
    }

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "accessoryCount": .int(accessoryCount)
        ])
    }
}

// MARK: - Zone Model

struct ZoneModel: Codable {
    let id: String
    let name: String
    let roomIds: [String]

    init(from zone: HMZone) {
        self.id = zone.uniqueIdentifier.uuidString
        self.name = zone.name
        self.roomIds = zone.rooms.map { $0.uniqueIdentifier.uuidString }
    }

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "roomIds": .array(roomIds.map { .string($0) })
        ])
    }
}

// MARK: - Service Group Model

struct ServiceGroupModel: Codable {
    let id: String
    let name: String
    let serviceIds: [String]
    let accessoryIds: [String]

    init(from group: HMServiceGroup) {
        self.id = group.uniqueIdentifier.uuidString
        self.name = group.name
        self.serviceIds = group.services.map { $0.uniqueIdentifier.uuidString }
        // Also include accessory IDs for convenience
        self.accessoryIds = Array(Set(group.services.compactMap { $0.accessory?.uniqueIdentifier.uuidString }))
    }

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "serviceIds": .array(serviceIds.map { .string($0) }),
            "accessoryIds": .array(accessoryIds.map { .string($0) })
        ])
    }
}

// MARK: - Accessory Model

struct AccessoryModel {
    let id: String
    let name: String
    let homeId: String?
    let roomId: String?
    let roomName: String?
    let category: String
    let isReachable: Bool
    let services: [ServiceModel]

    init(from accessory: HMAccessory, homeId: String? = nil, includeValues: Bool = true) {
        self.id = accessory.uniqueIdentifier.uuidString
        self.name = accessory.name
        self.homeId = homeId
        self.roomId = accessory.room?.uniqueIdentifier.uuidString
        self.roomName = accessory.room?.name
        self.category = accessory.category.localizedDescription
        self.isReachable = accessory.isReachable
        self.services = accessory.services.map { ServiceModel(from: $0, includeValues: includeValues) }
    }

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "category": .string(category),
            "isReachable": .bool(isReachable),
            "services": .array(services.map { $0.toJSON() })
        ]
        if let homeId = homeId {
            obj["homeId"] = .string(homeId)
        }
        if let roomId = roomId {
            obj["roomId"] = .string(roomId)
        }
        if let roomName = roomName {
            obj["roomName"] = .string(roomName)
        }
        return .object(obj)
    }
}

// MARK: - Service Model

struct ServiceModel {
    let id: String
    let name: String
    let serviceType: String
    let characteristics: [CharacteristicModel]

    init(from service: HMService, includeValues: Bool = true) {
        self.id = service.uniqueIdentifier.uuidString
        self.name = service.name
        self.serviceType = CharacteristicMapper.fromHomeKitServiceType(service.serviceType)
        self.characteristics = service.characteristics.map { CharacteristicModel(from: $0, includeValue: includeValues) }
    }

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "serviceType": .string(serviceType),
            "characteristics": .array(characteristics.map { $0.toJSON() })
        ])
    }
}

// MARK: - Characteristic Model

struct CharacteristicModel {
    let id: String
    let characteristicType: String
    let rawValue: Any?
    let isReadable: Bool
    let isWritable: Bool
    // Metadata from HomeKit
    let validValues: [NSNumber]?
    let minValue: NSNumber?
    let maxValue: NSNumber?
    let stepValue: NSNumber?

    init(from characteristic: HMCharacteristic, includeValue: Bool = true) {
        self.id = characteristic.uniqueIdentifier.uuidString
        self.characteristicType = CharacteristicMapper.fromHomeKitType(characteristic.characteristicType)
        // Note: Accessing .value can trigger network reads on some devices
        // For large accessory lists, skip values for performance
        self.rawValue = includeValue ? characteristic.value : nil
        self.isReadable = characteristic.properties.contains(HMCharacteristicPropertyReadable)
        self.isWritable = characteristic.properties.contains(HMCharacteristicPropertyWritable)
        // Extract metadata
        self.validValues = characteristic.metadata?.validValues
        self.minValue = characteristic.metadata?.minimumValue
        self.maxValue = characteristic.metadata?.maximumValue
        self.stepValue = characteristic.metadata?.stepValue
    }

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "characteristicType": .string(characteristicType),
            "isReadable": .bool(isReadable),
            "isWritable": .bool(isWritable)
        ]
        if let value = rawValue {
            obj["value"] = convertToJSONValue(value)
        }
        // Include metadata if available
        if let validValues = validValues, !validValues.isEmpty {
            obj["validValues"] = .array(validValues.map { convertToJSONValue($0) })
        }
        if let minValue = minValue {
            obj["minValue"] = convertToJSONValue(minValue)
        }
        if let maxValue = maxValue {
            obj["maxValue"] = convertToJSONValue(maxValue)
        }
        if let stepValue = stepValue {
            obj["stepValue"] = convertToJSONValue(stepValue)
        }
        return .object(obj)
    }

    private func convertToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let b as Bool:
            return .bool(b)
        case let i as Int:
            return .int(i)
        case let d as Double:
            return .double(d)
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            // NSNumber can be bool, int, or double - check type
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            } else if n.doubleValue == Double(n.intValue) {
                return .int(n.intValue)
            } else {
                return .double(n.doubleValue)
            }
        default:
            // Fallback to string representation
            return .string(String(describing: value))
        }
    }
}

// MARK: - Scene Model

struct SceneModel: Codable {
    let id: String
    let name: String
    let actionCount: Int
    let actionSetType: String
    let automationName: String?  // Non-nil if this scene is used by an automation

    init(from actionSet: HMActionSet, automationName: String? = nil) {
        self.id = actionSet.uniqueIdentifier.uuidString
        self.name = actionSet.name
        self.actionCount = actionSet.actions.count
        self.actionSetType = actionSet.actionSetType
        self.automationName = automationName
    }

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "actionCount": .int(actionCount),
            "actionSetType": .string(actionSetType)
        ]
        if let v = automationName { obj["automationName"] = .string(v) }
        return .object(obj)
    }
}

// MARK: - Automation Models

struct AutomationActionModel {
    let accessoryId: String
    let accessoryName: String
    let characteristicType: String
    let targetValue: JSONValue

    init(from action: HMCharacteristicWriteAction<NSCopying>) {
        let characteristic = action.characteristic
        let accessory = characteristic.service?.accessory
        self.accessoryId = accessory?.uniqueIdentifier.uuidString ?? ""
        self.accessoryName = accessory?.name ?? "Unknown"
        self.characteristicType = CharacteristicMapper.fromHomeKitType(characteristic.characteristicType)
        self.targetValue = JSONValue.from(action.targetValue)
    }

    init(accessoryId: String, accessoryName: String, characteristicType: String, targetValue: JSONValue) {
        self.accessoryId = accessoryId
        self.accessoryName = accessoryName
        self.characteristicType = characteristicType
        self.targetValue = targetValue
    }

    func toJSON() -> JSONValue {
        .object([
            "accessoryId": .string(accessoryId),
            "accessoryName": .string(accessoryName),
            "characteristicType": .string(characteristicType),
            "targetValue": targetValue
        ])
    }
}

struct AutomationEventModel {
    let type: String
    // Characteristic event fields
    let accessoryId: String?
    let accessoryName: String?
    let characteristicType: String?
    let triggerValue: JSONValue?
    // Threshold range fields
    let thresholdMin: JSONValue?
    let thresholdMax: JSONValue?
    // Significant time fields
    let significantEvent: String?
    let offsetMinutes: Int?
    // Location fields
    let latitude: Double?
    let longitude: Double?
    let radius: Double?
    let notifyOnEntry: Bool?
    let notifyOnExit: Bool?
    // Presence fields
    let presenceType: String?
    let presenceEvent: String?
    // Calendar fields
    let calendarComponents: [String: Int]?
    // Duration fields
    let durationSeconds: Double?

    static func from(event: HMEvent) -> AutomationEventModel {
        // HMCharacteristicEvent is generic — try multiple cast approaches
        // First try the direct generic cast
        if let charEvent = event as? HMCharacteristicEvent<NSCopying> {
            let characteristic = charEvent.characteristic
            let accessory = characteristic.service?.accessory
            return AutomationEventModel(
                type: "characteristic",
                accessoryId: accessory?.uniqueIdentifier.uuidString,
                accessoryName: accessory?.name,
                characteristicType: CharacteristicMapper.fromHomeKitType(characteristic.characteristicType),
                triggerValue: charEvent.triggerValue.map { JSONValue.from($0) },
                thresholdMin: nil, thresholdMax: nil,
                significantEvent: nil, offsetMinutes: nil,
                latitude: nil, longitude: nil, radius: nil,
                notifyOnEntry: nil, notifyOnExit: nil,
                presenceType: nil, presenceEvent: nil,
                calendarComponents: nil, durationSeconds: nil
            )
        }
        // Fallback: try NSNumber and NSString generic variants
        if let charEvent = event as? HMCharacteristicEvent<NSNumber> {
            let characteristic = charEvent.characteristic
            let accessory = characteristic.service?.accessory
            return AutomationEventModel(
                type: "characteristic",
                accessoryId: accessory?.uniqueIdentifier.uuidString,
                accessoryName: accessory?.name,
                characteristicType: CharacteristicMapper.fromHomeKitType(characteristic.characteristicType),
                triggerValue: charEvent.triggerValue.map { JSONValue.from($0) },
                thresholdMin: nil, thresholdMax: nil,
                significantEvent: nil, offsetMinutes: nil,
                latitude: nil, longitude: nil, radius: nil,
                notifyOnEntry: nil, notifyOnExit: nil,
                presenceType: nil, presenceEvent: nil,
                calendarComponents: nil, durationSeconds: nil
            )
        }
        if let charEvent = event as? HMCharacteristicEvent<NSString> {
            let characteristic = charEvent.characteristic
            let accessory = characteristic.service?.accessory
            return AutomationEventModel(
                type: "characteristic",
                accessoryId: accessory?.uniqueIdentifier.uuidString,
                accessoryName: accessory?.name,
                characteristicType: CharacteristicMapper.fromHomeKitType(characteristic.characteristicType),
                triggerValue: charEvent.triggerValue.map { JSONValue.from($0) },
                thresholdMin: nil, thresholdMax: nil,
                significantEvent: nil, offsetMinutes: nil,
                latitude: nil, longitude: nil, radius: nil,
                notifyOnEntry: nil, notifyOnExit: nil,
                presenceType: nil, presenceEvent: nil,
                calendarComponents: nil, durationSeconds: nil
            )
        }

        if let sigEvent = event as? HMSignificantTimeEvent {
            let eventName: String
            if sigEvent.significantEvent == HMSignificantEvent.sunrise {
                eventName = "sunrise"
            } else if sigEvent.significantEvent == HMSignificantEvent.sunset {
                eventName = "sunset"
            } else {
                eventName = "unknown"
            }
            let offset = sigEvent.offset
            let totalMinutes: Int?
            if let offset = offset {
                totalMinutes = (offset.hour ?? 0) * 60 + (offset.minute ?? 0)
            } else {
                totalMinutes = nil
            }
            return AutomationEventModel(
                type: "significantTime",
                accessoryId: nil, accessoryName: nil, characteristicType: nil,
                triggerValue: nil, thresholdMin: nil, thresholdMax: nil,
                significantEvent: eventName, offsetMinutes: totalMinutes,
                latitude: nil, longitude: nil, radius: nil,
                notifyOnEntry: nil, notifyOnExit: nil,
                presenceType: nil, presenceEvent: nil,
                calendarComponents: nil, durationSeconds: nil
            )
        }

        if let locEvent = event as? HMLocationEvent,
           let circularRegion = locEvent.region as? CLCircularRegion {
            return AutomationEventModel(
                type: "location",
                accessoryId: nil, accessoryName: nil, characteristicType: nil,
                triggerValue: nil, thresholdMin: nil, thresholdMax: nil,
                significantEvent: nil, offsetMinutes: nil,
                latitude: circularRegion.center.latitude,
                longitude: circularRegion.center.longitude,
                radius: circularRegion.radius,
                notifyOnEntry: circularRegion.notifyOnEntry,
                notifyOnExit: circularRegion.notifyOnExit,
                presenceType: nil, presenceEvent: nil,
                calendarComponents: nil, durationSeconds: nil
            )
        }

        if let presEvent = event as? HMPresenceEvent {
            let pType: String
            switch presEvent.presenceUserType {
            case .currentUser: pType = "currentUser"
            case .homeUsers: pType = "allUsers"
            case .customUsers: pType = "customUsers"
            @unknown default: pType = "unknown"
            }
            let pEvent: String
            switch presEvent.presenceEventType {
            case .everyEntry: pEvent = "atHome"
            case .everyExit: pEvent = "notAtHome"
            case .firstEntry: pEvent = "firstArrival"
            case .lastExit: pEvent = "lastDeparture"
            @unknown default: pEvent = "unknown"
            }
            return AutomationEventModel(
                type: "presence",
                accessoryId: nil, accessoryName: nil, characteristicType: nil,
                triggerValue: nil, thresholdMin: nil, thresholdMax: nil,
                significantEvent: nil, offsetMinutes: nil,
                latitude: nil, longitude: nil, radius: nil,
                notifyOnEntry: nil, notifyOnExit: nil,
                presenceType: pType, presenceEvent: pEvent,
                calendarComponents: nil, durationSeconds: nil
            )
        }

        if let calEvent = event as? HMCalendarEvent {
            var components: [String: Int] = [:]
            let dc = calEvent.fireDateComponents
            if let hour = dc.hour { components["hour"] = hour }
            if let minute = dc.minute { components["minute"] = minute }
            if let day = dc.day { components["day"] = day }
            if let month = dc.month { components["month"] = month }
            if let weekday = dc.weekday { components["weekday"] = weekday }
            return AutomationEventModel(
                type: "calendar",
                accessoryId: nil, accessoryName: nil, characteristicType: nil,
                triggerValue: nil, thresholdMin: nil, thresholdMax: nil,
                significantEvent: nil, offsetMinutes: nil,
                latitude: nil, longitude: nil, radius: nil,
                notifyOnEntry: nil, notifyOnExit: nil,
                presenceType: nil, presenceEvent: nil,
                calendarComponents: components, durationSeconds: nil
            )
        }

        if let durEvent = event as? HMDurationEvent {
            return AutomationEventModel(
                type: "duration",
                accessoryId: nil, accessoryName: nil, characteristicType: nil,
                triggerValue: nil, thresholdMin: nil, thresholdMax: nil,
                significantEvent: nil, offsetMinutes: nil,
                latitude: nil, longitude: nil, radius: nil,
                notifyOnEntry: nil, notifyOnExit: nil,
                presenceType: nil, presenceEvent: nil,
                calendarComponents: nil, durationSeconds: durEvent.duration
            )
        }

        return AutomationEventModel(
            type: "unknown",
            accessoryId: nil, accessoryName: nil, characteristicType: nil,
            triggerValue: nil, thresholdMin: nil, thresholdMax: nil,
            significantEvent: nil, offsetMinutes: nil,
            latitude: nil, longitude: nil, radius: nil,
            notifyOnEntry: nil, notifyOnExit: nil,
            presenceType: nil, presenceEvent: nil,
            calendarComponents: nil, durationSeconds: nil
        )
    }

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["type": .string(type)]
        if let v = accessoryId { obj["accessoryId"] = .string(v) }
        if let v = accessoryName { obj["accessoryName"] = .string(v) }
        if let v = characteristicType { obj["characteristicType"] = .string(v) }
        if let v = triggerValue { obj["triggerValue"] = v }
        if let v = thresholdMin { obj["thresholdMin"] = v }
        if let v = thresholdMax { obj["thresholdMax"] = v }
        if let v = significantEvent { obj["significantEvent"] = .string(v) }
        if let v = offsetMinutes { obj["offsetMinutes"] = .int(v) }
        if let v = latitude { obj["latitude"] = .double(v) }
        if let v = longitude { obj["longitude"] = .double(v) }
        if let v = radius { obj["radius"] = .double(v) }
        if let v = notifyOnEntry { obj["notifyOnEntry"] = .bool(v) }
        if let v = notifyOnExit { obj["notifyOnExit"] = .bool(v) }
        if let v = presenceType { obj["presenceType"] = .string(v) }
        if let v = presenceEvent { obj["presenceEvent"] = .string(v) }
        if let v = calendarComponents {
            obj["calendarComponents"] = .object(v.mapValues { .int($0) })
        }
        if let v = durationSeconds { obj["durationSeconds"] = .double(v) }
        return .object(obj)
    }
}

// MARK: - Automation Condition Model (from NSPredicate)

struct AutomationConditionModel {
    let type: String  // "characteristic", "time", "significantEvent", "presence", "unknown"
    // Characteristic condition (merged from compound predicate pair)
    let accessoryId: String?
    let accessoryName: String?
    let characteristicType: String?
    let comparisonOperator: String?  // "equalTo", "lessThan", "greaterThan", "lessThanOrEqualTo", "greaterThanOrEqualTo"
    let value: JSONValue?
    // Time condition
    let beforeTime: [String: Int]?
    let afterTime: [String: Int]?
    // Significant event condition
    let beforeEvent: String?  // "sunrise" or "sunset"
    let afterEvent: String?
    // Fallback
    let predicateFormat: String?

    static func from(predicate: NSPredicate?) -> [AutomationConditionModel] {
        guard let predicate = predicate else { return [] }

        if let compound = predicate as? NSCompoundPredicate {
            // Check if this is a characteristic condition pair (identity + value)
            if compound.compoundPredicateType == .and,
               compound.subpredicates.count == 2,
               let sub0 = compound.subpredicates[0] as? NSComparisonPredicate,
               let sub1 = compound.subpredicates[1] as? NSComparisonPredicate {
                let merged = mergeCharacteristicPair(sub0, sub1)
                if let merged = merged { return [merged] }
            }
            // Otherwise flatten all subpredicates
            return compound.subpredicates.flatMap { sub in
                from(predicate: sub as? NSPredicate)
            }
        }

        if let comparison = predicate as? NSComparisonPredicate {
            return [parseComparison(comparison)]
        }

        return [AutomationConditionModel(
            type: "unknown", accessoryId: nil, accessoryName: nil,
            characteristicType: nil, comparisonOperator: nil, value: nil,
            beforeTime: nil, afterTime: nil, beforeEvent: nil, afterEvent: nil,
            predicateFormat: predicate.predicateFormat
        )]
    }

    /// Merge a characteristic identity + value predicate pair into one condition
    private static func mergeCharacteristicPair(_ a: NSComparisonPredicate, _ b: NSComparisonPredicate) -> AutomationConditionModel? {
        var charPred: NSComparisonPredicate?
        var valuePred: NSComparisonPredicate?

        for pred in [a, b] {
            if pred.leftExpression.expressionType == .keyPath {
                if pred.leftExpression.keyPath == HMCharacteristicKeyPath { charPred = pred }
                else if pred.leftExpression.keyPath == HMCharacteristicValueKeyPath { valuePred = pred }
            }
        }

        guard let charPred = charPred, let valuePred = valuePred else { return nil }

        let characteristic = charPred.rightExpression.constantValue as? HMCharacteristic
        let accessory = characteristic?.service?.accessory

        return AutomationConditionModel(
            type: "characteristic",
            accessoryId: accessory?.uniqueIdentifier.uuidString,
            accessoryName: accessory?.name,
            characteristicType: characteristic.map { CharacteristicMapper.fromHomeKitType($0.characteristicType) },
            comparisonOperator: mapOperator(valuePred.predicateOperatorType),
            value: valuePred.rightExpression.constantValue.map { JSONValue.from($0) },
            beforeTime: nil, afterTime: nil, beforeEvent: nil, afterEvent: nil,
            predicateFormat: nil
        )
    }

    private static func parseComparison(_ pred: NSComparisonPredicate) -> AutomationConditionModel {
        let left = pred.leftExpression
        let right = pred.rightExpression

        // Time condition: one side is now() function, other is DateComponents
        if left.expressionType == .function || right.expressionType == .function {
            let dateComponents: NSDateComponents? =
                (right.constantValue as? NSDateComponents) ?? (left.constantValue as? NSDateComponents)

            if let dc = dateComponents {
                var timeDict: [String: Int] = [:]
                if dc.hour != NSDateComponentUndefined { timeDict["hour"] = dc.hour }
                if dc.minute != NSDateComponentUndefined { timeDict["minute"] = dc.minute }

                let isBefore = pred.predicateOperatorType == .lessThan
                return AutomationConditionModel(
                    type: "time", accessoryId: nil, accessoryName: nil,
                    characteristicType: nil, comparisonOperator: nil, value: nil,
                    beforeTime: isBefore ? timeDict : nil,
                    afterTime: isBefore ? nil : timeDict,
                    beforeEvent: nil, afterEvent: nil, predicateFormat: nil
                )
            }
        }

        // Significant event: keyPath contains sunrise/sunset
        if left.expressionType == .keyPath {
            let kp = left.keyPath.lowercased()
            if kp.contains("sunrise") || kp.contains("sunset") {
                let event = kp.contains("sunrise") ? "sunrise" : "sunset"
                // INVERTED: .lessThan means "after" (event < now = event already happened)
                let isAfter = pred.predicateOperatorType == .lessThan || pred.predicateOperatorType == .lessThanOrEqualTo
                return AutomationConditionModel(
                    type: "significantEvent", accessoryId: nil, accessoryName: nil,
                    characteristicType: nil, comparisonOperator: nil, value: nil,
                    beforeTime: nil, afterTime: nil,
                    beforeEvent: isAfter ? nil : event,
                    afterEvent: isAfter ? event : nil,
                    predicateFormat: nil
                )
            }

            // Presence condition
            if left.keyPath == HMPresenceKeyPath {
                return AutomationConditionModel(
                    type: "presence", accessoryId: nil, accessoryName: nil,
                    characteristicType: nil, comparisonOperator: nil, value: nil,
                    beforeTime: nil, afterTime: nil, beforeEvent: nil, afterEvent: nil,
                    predicateFormat: pred.predicateFormat
                )
            }

            // Standalone characteristic keypath (shouldn't happen outside pair, but handle gracefully)
            if left.keyPath == HMCharacteristicKeyPath {
                if let char = right.constantValue as? HMCharacteristic {
                    let accessory = char.service?.accessory
                    return AutomationConditionModel(
                        type: "characteristic",
                        accessoryId: accessory?.uniqueIdentifier.uuidString,
                        accessoryName: accessory?.name,
                        characteristicType: CharacteristicMapper.fromHomeKitType(char.characteristicType),
                        comparisonOperator: nil, value: nil,
                        beforeTime: nil, afterTime: nil, beforeEvent: nil, afterEvent: nil,
                        predicateFormat: nil
                    )
                }
            }
            if left.keyPath == HMCharacteristicValueKeyPath {
                return AutomationConditionModel(
                    type: "characteristic",
                    accessoryId: nil, accessoryName: nil, characteristicType: nil,
                    comparisonOperator: mapOperator(pred.predicateOperatorType),
                    value: right.constantValue.map { JSONValue.from($0) },
                    beforeTime: nil, afterTime: nil, beforeEvent: nil, afterEvent: nil,
                    predicateFormat: nil
                )
            }
        }

        // Fallback
        return AutomationConditionModel(
            type: "unknown", accessoryId: nil, accessoryName: nil,
            characteristicType: nil, comparisonOperator: nil, value: nil,
            beforeTime: nil, afterTime: nil, beforeEvent: nil, afterEvent: nil,
            predicateFormat: pred.predicateFormat
        )
    }

    private static func mapOperator(_ op: NSComparisonPredicate.Operator) -> String {
        switch op {
        case .equalTo: return "equalTo"
        case .lessThan: return "lessThan"
        case .greaterThan: return "greaterThan"
        case .lessThanOrEqualTo: return "lessThanOrEqualTo"
        case .greaterThanOrEqualTo: return "greaterThanOrEqualTo"
        case .notEqualTo: return "notEqualTo"
        default: return "equalTo"
        }
    }

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["type": .string(type)]
        if let v = accessoryId { obj["accessoryId"] = .string(v) }
        if let v = accessoryName { obj["accessoryName"] = .string(v) }
        if let v = characteristicType { obj["characteristicType"] = .string(v) }
        if let v = comparisonOperator { obj["operator"] = .string(v) }
        if let v = value { obj["value"] = v }
        if let v = beforeTime { obj["beforeTime"] = .object(v.mapValues { .int($0) }) }
        if let v = afterTime { obj["afterTime"] = .object(v.mapValues { .int($0) }) }
        if let v = beforeEvent { obj["beforeEvent"] = .string(v) }
        if let v = afterEvent { obj["afterEvent"] = .string(v) }
        if let v = predicateFormat { obj["predicateFormat"] = .string(v) }
        return .object(obj)
    }
}

struct AutomationTriggerModel {
    let type: String  // "timer" or "event"
    // Timer fields
    let fireDate: String?
    let recurrence: [String: Int]?
    let timeZone: String?
    // Event fields
    let events: [AutomationEventModel]?
    let endEvents: [AutomationEventModel]?
    let recurrences: [[String: Int]]?
    let conditions: [AutomationConditionModel]?
    let executeOnce: Bool?
    let activationState: String?

    static func from(trigger: HMTrigger) -> AutomationTriggerModel {
        if let timer = trigger as? HMTimerTrigger {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            var recurrence: [String: Int]? = nil
            if let rc = timer.recurrence {
                var dict: [String: Int] = [:]
                if let hour = rc.hour, hour != NSDateComponentUndefined { dict["hour"] = hour }
                if let minute = rc.minute, minute != NSDateComponentUndefined { dict["minute"] = minute }
                if let day = rc.day, day != NSDateComponentUndefined { dict["day"] = day }
                if let weekday = rc.weekday, weekday != NSDateComponentUndefined { dict["weekday"] = weekday }
                if let month = rc.month, month != NSDateComponentUndefined { dict["month"] = month }
                if !dict.isEmpty { recurrence = dict }
            }
            return AutomationTriggerModel(
                type: "timer",
                fireDate: formatter.string(from: timer.fireDate),
                recurrence: recurrence,
                timeZone: timer.timeZone?.identifier,
                events: nil, endEvents: nil, recurrences: nil, conditions: nil,
                executeOnce: nil, activationState: nil
            )
        }

        if let eventTrigger = trigger as? HMEventTrigger {
            // For triggers with no public events, try to extract internal data via NSKeyedArchiver
            let events = eventTrigger.events.map { AutomationEventModel.from(event: $0) }
            let endEvents = eventTrigger.endEvents.map { AutomationEventModel.from(event: $0) }
            let recurrences: [[String: Int]]? = eventTrigger.recurrences?.compactMap { dc in
                var dict: [String: Int] = [:]
                if let hour = dc.hour { dict["hour"] = hour }
                if let minute = dc.minute { dict["minute"] = minute }
                if let day = dc.day { dict["day"] = day }
                if let weekday = dc.weekday { dict["weekday"] = weekday }
                if let month = dc.month { dict["month"] = month }
                if let weekOfYear = dc.weekOfYear { dict["weekOfYear"] = weekOfYear }
                return dict.isEmpty ? nil : dict
            }
            let activationState: String
            switch eventTrigger.triggerActivationState {
            case .enabled: activationState = "enabled"
            case .disabled: activationState = "disabled"
            case .disabledNoHomeHub: activationState = "disabledNoHomeHub"
            case .disabledNoCompatibleHomeHub: activationState = "disabledNoCompatibleHomeHub"
            case .disabledNoLocationServicesAuthorization: activationState = "disabledNoLocationServices"
            @unknown default: activationState = "unknown"
            }
            // Parse predicate conditions — always include predicateFormat for debugging
            var conditions: [AutomationConditionModel] = []
            if let predicate = eventTrigger.predicate {
                let parsed = AutomationConditionModel.from(predicate: predicate)
                if parsed.isEmpty {
                    // Predicate exists but couldn't be parsed — include raw format
                    conditions = [AutomationConditionModel(
                        type: "unknown", accessoryId: nil, accessoryName: nil,
                        characteristicType: nil, comparisonOperator: nil, value: nil,
                        beforeTime: nil, afterTime: nil, beforeEvent: nil, afterEvent: nil,
                        predicateFormat: predicate.predicateFormat
                    )]
                } else {
                    conditions = parsed
                }
            }
            return AutomationTriggerModel(
                type: "event",
                fireDate: nil, recurrence: nil, timeZone: nil,
                events: events,
                endEvents: endEvents.isEmpty ? nil : endEvents,
                recurrences: recurrences,
                conditions: conditions.isEmpty ? nil : conditions,
                executeOnce: eventTrigger.executeOnce,
                activationState: activationState
            )
        }

        return AutomationTriggerModel(
            type: "unknown",
            fireDate: nil, recurrence: nil, timeZone: nil,
            events: nil, endEvents: nil, recurrences: nil, conditions: nil,
            executeOnce: nil, activationState: nil
        )
    }

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["type": .string(type)]
        if let v = fireDate { obj["fireDate"] = .string(v) }
        if let v = recurrence { obj["recurrence"] = .object(v.mapValues { .int($0) }) }
        if let v = timeZone { obj["timeZone"] = .string(v) }
        if let v = events { obj["events"] = .array(v.map { $0.toJSON() }) }
        if let v = endEvents { obj["endEvents"] = .array(v.map { $0.toJSON() }) }
        if let v = recurrences {
            obj["recurrences"] = .array(v.map { .object($0.mapValues { .int($0) }) })
        }
        if let v = conditions { obj["conditions"] = .array(v.map { $0.toJSON() }) }
        if let v = executeOnce { obj["executeOnce"] = .bool(v) }
        if let v = activationState { obj["activationState"] = .string(v) }
        return .object(obj)
    }
}

struct AutomationModel {
    let id: String
    let name: String
    let isEnabled: Bool
    let trigger: AutomationTriggerModel
    let actions: [AutomationActionModel]
    let lastFireDate: String?
    let homeId: String

    init(from trigger: HMTrigger, homeId: String) {
        self.id = trigger.uniqueIdentifier.uuidString
        self.name = trigger.name
        self.isEnabled = trigger.isEnabled
        self.trigger = AutomationTriggerModel.from(trigger: trigger)
        self.homeId = homeId

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.lastFireDate = trigger.lastFireDate.map { formatter.string(from: $0) }

        // Walk action sets → actions → HMCharacteristicWriteAction
        var allActions: [AutomationActionModel] = []
        for actionSet in trigger.actionSets {
            for action in actionSet.actions {
                if let writeAction = action as? HMCharacteristicWriteAction<NSCopying> {
                    allActions.append(AutomationActionModel(from: writeAction))
                }
            }
        }
        self.actions = allActions
    }

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "isEnabled": .bool(isEnabled),
            "trigger": trigger.toJSON(),
            "actions": .array(actions.map { $0.toJSON() }),
            "homeId": .string(homeId)
        ]
        if let v = lastFireDate { obj["lastFireDate"] = .string(v) }
        return .object(obj)
    }
}

// MARK: - Result Models

struct ControlResult: Codable {
    let success: Bool
    let accessoryId: String
    let characteristic: String
    let newValue: String

    func toJSON() -> JSONValue {
        .object([
            "success": .bool(success),
            "accessoryId": .string(accessoryId),
            "characteristic": .string(characteristic),
            "newValue": .string(newValue)
        ])
    }
}

struct ExecuteResult: Codable {
    let success: Bool
    let sceneId: String

    func toJSON() -> JSONValue {
        .object([
            "success": .bool(success),
            "sceneId": .string(sceneId)
        ])
    }
}

// MARK: - Errors

enum HomeKitError: LocalizedError {
    case homeNotFound(String)
    case roomNotFound(String)
    case accessoryNotFound(String)
    case sceneNotFound(String)
    case characteristicNotFound(String)
    case characteristicNotWritable(String)
    case invalidId(String)
    case invalidRequest(String)
    case readFailed(Error)
    case writeFailed(Error)
    case sceneExecutionFailed(Error)
    case automationNotFound(String)
    case automationCreationFailed(Error)
    case automationUpdateFailed(Error)
    case automationDeletionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .homeNotFound(let id):
            return "Home not found: \(id)"
        case .roomNotFound(let id):
            return "Room not found: \(id)"
        case .accessoryNotFound(let id):
            return "Accessory not found: \(id)"
        case .sceneNotFound(let id):
            return "Scene not found: \(id)"
        case .characteristicNotFound(let type):
            return "Characteristic not found: \(type)"
        case .characteristicNotWritable(let type):
            return "Characteristic not writable: \(type)"
        case .invalidId(let id):
            return "Invalid ID format: \(id)"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        case .readFailed(let error):
            return "Read failed: \(error.localizedDescription)"
        case .writeFailed(let error):
            return "Write failed: \(error.localizedDescription)"
        case .sceneExecutionFailed(let error):
            return "Scene execution failed: \(error.localizedDescription)"
        case .automationNotFound(let id):
            return "Automation not found: \(id)"
        case .automationCreationFailed(let error):
            return "Automation creation failed: \(error.localizedDescription)"
        case .automationUpdateFailed(let error):
            return "Automation update failed: \(error.localizedDescription)"
        case .automationDeletionFailed(let error):
            return "Automation deletion failed: \(error.localizedDescription)"
        }
    }

    var code: String {
        switch self {
        case .homeNotFound:
            return "HOME_NOT_FOUND"
        case .roomNotFound:
            return "ROOM_NOT_FOUND"
        case .accessoryNotFound:
            return "ACCESSORY_NOT_FOUND"
        case .sceneNotFound:
            return "SCENE_NOT_FOUND"
        case .characteristicNotFound:
            return "CHARACTERISTIC_NOT_FOUND"
        case .characteristicNotWritable:
            return "CHARACTERISTIC_NOT_WRITABLE"
        case .invalidId:
            return "INVALID_ID"
        case .invalidRequest:
            return "INVALID_REQUEST"
        case .readFailed:
            return "READ_FAILED"
        case .writeFailed:
            return "WRITE_FAILED"
        case .sceneExecutionFailed:
            return "SCENE_EXECUTION_FAILED"
        case .automationNotFound:
            return "AUTOMATION_NOT_FOUND"
        case .automationCreationFailed:
            return "AUTOMATION_CREATION_FAILED"
        case .automationUpdateFailed:
            return "AUTOMATION_UPDATE_FAILED"
        case .automationDeletionFailed:
            return "AUTOMATION_DELETION_FAILED"
        }
    }
}
