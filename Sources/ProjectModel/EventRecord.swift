import Foundation

// Swift mirror of `Schemas/event-record-v1.schema.json`. One record per line
// of an event chunk; times are nanoseconds on the session monotonic origin;
// coordinates are global physical pixels plus a display ID.

public enum EventType: String, Codable, Sendable {
    case cursorMove
    case mouseDown
    case mouseUp
    case scrollWheel
    case cursorShapeChanged
    case keyDown
    case keyUp
    case flagsChanged
}

public enum MouseButton: String, Codable, Sendable {
    case left, right, other
}

public enum EventModifier: String, Codable, Sendable {
    case capsLock, shift, control, option, command, fn
}

public struct EventRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sequence: UInt64
    public var timeNs: Int64
    public var type: EventType
    public var displayID: Int?
    public var xPx: Double?
    public var yPx: Double?
    public var cursorID: String?
    public var buttons: Int?
    public var button: MouseButton?
    public var clickCount: Int?
    public var pressure: Double?
    public var modifiers: [EventModifier]?
    public var deltaX: Double?
    public var deltaY: Double?
    public var keyCode: Int?
    public var characters: String?
    public var isSecureInput: Bool?

    public init(
        sequence: UInt64,
        timeNs: Int64,
        type: EventType,
        displayID: Int? = nil,
        xPx: Double? = nil,
        yPx: Double? = nil,
        cursorID: String? = nil,
        buttons: Int? = nil,
        button: MouseButton? = nil,
        clickCount: Int? = nil,
        pressure: Double? = nil,
        modifiers: [EventModifier]? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        keyCode: Int? = nil,
        characters: String? = nil,
        isSecureInput: Bool? = nil
    ) {
        self.schemaVersion = ProjectSchema.currentVersion
        self.sequence = sequence
        self.timeNs = timeNs
        self.type = type
        self.displayID = displayID
        self.xPx = xPx
        self.yPx = yPx
        self.cursorID = cursorID
        self.buttons = buttons
        self.button = button
        self.clickCount = clickCount
        self.pressure = pressure
        self.modifiers = modifiers
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.keyCode = keyCode
        self.characters = characters
        self.isSecureInput = isSecureInput
    }

    /// Which chunk family this record is persisted into.
    public var chunkKind: EventChunkKind {
        switch type {
        case .cursorMove, .scrollWheel, .cursorShapeChanged:
            return .cursor
        case .mouseDown, .mouseUp:
            return .clicks
        case .keyDown, .keyUp, .flagsChanged:
            return .keyboard
        }
    }

    /// Structural validation matching the schema's conditional requirements.
    public func structuralProblems() -> [String] {
        var problems: [String] = []
        switch type {
        case .cursorMove, .mouseDown, .mouseUp:
            if displayID == nil || xPx == nil || yPx == nil {
                problems.append("\(type.rawValue) requires displayID/xPx/yPx (sequence \(sequence))")
            }
        default:
            break
        }
        if (type == .mouseDown || type == .mouseUp) && button == nil {
            problems.append("\(type.rawValue) requires button (sequence \(sequence))")
        }
        if type == .cursorShapeChanged && cursorID == nil {
            problems.append("cursorShapeChanged requires cursorID (sequence \(sequence))")
        }
        return problems
    }
}

/// Swift mirror of `Schemas/cursor-descriptor-v1.schema.json`.
public struct CursorDescriptor: Codable, Sendable, Equatable {
    public enum SemanticFamily: String, Codable, Sendable {
        case arrow, iBeam, pointingHand, crosshair
        case resizeLeftRight, resizeUpDown, openHand, closedHand
        case contextualMenu, dragCopy, dragLink, disappearingItem
        case operationNotAllowed, unknown
    }

    public enum SourceType: String, Codable, Sendable {
        case nscursor, system, custom
    }

    public var schemaVersion: Int
    public var id: String
    public var semanticFamily: SemanticFamily
    public var sourceType: SourceType
    public var widthPx: Double
    public var heightPx: Double
    public var backingScale: Double
    public var hotspotXPx: Double
    public var hotspotYPx: Double
    public var imagePath: String?
    public var imageSHA256: String?

    public init(
        id: String,
        semanticFamily: SemanticFamily,
        sourceType: SourceType,
        widthPx: Double,
        heightPx: Double,
        backingScale: Double,
        hotspotXPx: Double,
        hotspotYPx: Double,
        imagePath: String? = nil,
        imageSHA256: String? = nil
    ) {
        self.schemaVersion = ProjectSchema.currentVersion
        self.id = id
        self.semanticFamily = semanticFamily
        self.sourceType = sourceType
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.backingScale = backingScale
        self.hotspotXPx = hotspotXPx
        self.hotspotYPx = hotspotYPx
        self.imagePath = imagePath
        self.imageSHA256 = imageSHA256
    }
}

// MARK: - JSONL coding

extension EventRecord {
    /// Single-line JSON without trailing newline, deterministic key order.
    public func jsonlLine() throws -> String {
        try JSONValue(encoding: self).canonicalString()
    }

    public static func parse(line: Substring, lineNumber: Int) throws -> EventRecord {
        guard let data = line.data(using: .utf8), !line.isEmpty else {
            throw ScreenreelError.invalidJSON("empty event line \(lineNumber)")
        }
        do {
            return try JSONDecoder().decode(EventRecord.self, from: data)
        } catch {
            throw ScreenreelError.invalidJSON("event line \(lineNumber): \(error)")
        }
    }
}
