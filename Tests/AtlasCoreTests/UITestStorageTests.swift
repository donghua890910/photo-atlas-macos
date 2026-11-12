import XCTest
@testable import AtlasCore

final class UITestStorageTests: XCTestCase {
    func testOnlyMarkedPrivateTemporaryDirectoryIsAccepted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoAtlasUITest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try UITestStorage.validatedDirectory(root.path))
        try UITestStorage.marker.write(to: root.appendingPathComponent(".photoatlas-ui-fixture"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try UITestStorage.validatedDirectory(root.path), root.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertThrowsError(try UITestStorage.validatedDirectory(FileManager.default.homeDirectoryForCurrentUser.path))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("atlas.sqlite"), withDestinationURL: root.appendingPathComponent("other.sqlite"))
        XCTAssertThrowsError(try UITestStorage.validatedDirectory(root.path))
    }
}
