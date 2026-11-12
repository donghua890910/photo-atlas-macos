import Foundation

public enum UITestStorage {
    public static let marker = "Photo Atlas isolated UI fixture v1"

    public static func validatedDirectory(_ path: String) throws -> URL {
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard path.hasPrefix("/"), root.deletingLastPathComponent() == temporary,
              root.lastPathComponent.hasPrefix("PhotoAtlasUITest-"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              try String(contentsOf: root.appendingPathComponent(".photoatlas-ui-fixture"), encoding: .utf8) == marker else { throw StoreError.invalidInput }
        for name in [".photoatlas-ui-fixture", "atlas.sqlite", "atlas.sqlite-wal", "atlas.sqlite-shm"] {
            if let kind = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)[.type] as? FileAttributeType,
               kind != .typeRegular { throw StoreError.invalidInput }
        }
        return root
    }
}
