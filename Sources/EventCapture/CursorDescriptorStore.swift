import AppKit
import Foundation
import ProjectModel

/// Snapshots cursor descriptors (`docs/TECHNICAL_DESIGN.md` §3): on shape
/// change the current system cursor's image, hotspot, and scale are persisted
/// once under `events/cursors/`, deduplicated by image hash. Returns the
/// stable descriptor ID that event records reference.
public actor CursorDescriptorStore {
    private let layout: ProjectLayout
    private var byImageHash: [String: String] = [:]  // image sha → descriptor id
    private var nextIndex = 1

    public init(layout: ProjectLayout) {
        self.layout = layout
    }

    /// Persist (or find) the descriptor for a cursor snapshot. `pngData`,
    /// dimensions, and hotspot are in source pixels of the snapshot image.
    public func descriptorID(
        pngData: Data?,
        family: CursorDescriptor.SemanticFamily,
        widthPx: Double,
        heightPx: Double,
        backingScale: Double,
        hotspotXPx: Double,
        hotspotYPx: Double
    ) throws -> String {
        let imageHash = pngData.map(Hashing.sha256Hex)
        if let imageHash, let existing = byImageHash[imageHash] {
            return existing
        }

        let index = nextIndex
        nextIndex += 1
        let id = "\(family.rawValue)-\(String(format: "%04d", index))"
        var imagePath: String?
        if let pngData {
            let imageURL = layout.cursorsDirectory
                .appendingPathComponent(ProjectLayout.cursorImageFileName(index: index))
            try AtomicFile.write(pngData, to: imageURL)
            imagePath = layout.relativePath(of: imageURL)
        }
        let descriptor = CursorDescriptor(
            id: id,
            semanticFamily: family,
            sourceType: .nscursor,
            widthPx: widthPx,
            heightPx: heightPx,
            backingScale: backingScale,
            hotspotXPx: hotspotXPx,
            hotspotYPx: hotspotYPx,
            imagePath: imagePath,
            imageSHA256: imageHash)
        let jsonURL = layout.cursorsDirectory
            .appendingPathComponent(ProjectLayout.cursorDescriptorFileName(index: index))
        try AtomicFile.writeJSON(descriptor, to: jsonURL)
        if let imageHash {
            byImageHash[imageHash] = id
        }
        return id
    }

    /// Snapshot an `NSCursor` (main-thread AppKit values passed in as plain
    /// data to keep the actor isolation clean).
    public static func snapshot(of cursor: NSCursor) -> (
        pngData: Data?, widthPx: Double, heightPx: Double,
        backingScale: Double, hotspotXPx: Double, hotspotYPx: Double
    ) {
        let image = cursor.image
        let pointSize = image.size
        var pngData: Data?
        var pixelWidth = pointSize.width
        var pixelHeight = pointSize.height
        if let rep = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide < $1.pixelsWide })
        {
            pixelWidth = Double(rep.pixelsWide)
            pixelHeight = Double(rep.pixelsHigh)
            pngData = rep.representation(using: .png, properties: [:])
        } else if let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        {
            pixelWidth = Double(rep.pixelsWide)
            pixelHeight = Double(rep.pixelsHigh)
            pngData = rep.representation(using: .png, properties: [:])
        }
        let scale = pointSize.width > 0 ? pixelWidth / pointSize.width : 1
        return (
            pngData,
            pixelWidth,
            pixelHeight,
            scale,
            cursor.hotSpot.x * scale,
            cursor.hotSpot.y * scale
        )
    }

    /// Best-effort semantic classification of the current system cursor.
    public static func family(matching cursor: NSCursor) -> CursorDescriptor.SemanticFamily {
        switch cursor {
        case NSCursor.arrow: return .arrow
        case NSCursor.iBeam: return .iBeam
        case NSCursor.pointingHand: return .pointingHand
        case NSCursor.crosshair: return .crosshair
        case NSCursor.openHand: return .openHand
        case NSCursor.closedHand: return .closedHand
        case NSCursor.resizeLeftRight: return .resizeLeftRight
        case NSCursor.resizeUpDown: return .resizeUpDown
        case NSCursor.contextualMenu: return .contextualMenu
        case NSCursor.dragCopy: return .dragCopy
        case NSCursor.dragLink: return .dragLink
        case NSCursor.disappearingItem: return .disappearingItem
        case NSCursor.operationNotAllowed: return .operationNotAllowed
        default: return .unknown
        }
    }
}
