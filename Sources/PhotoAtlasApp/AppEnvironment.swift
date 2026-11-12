import Foundation
import AtlasCore

@MainActor enum AppEnvironment {
    static private(set) var support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Photo Atlas", isDirectory: true)
    static private(set) var isUITest = false
    static var database: URL { support.appendingPathComponent("atlas.sqlite") }

    static func configure(arguments: [String]) throws {
        let environmentPath = ProcessInfo.processInfo.environment["PHOTO_ATLAS_UI_TEST_DATA"]
        guard environmentPath != nil || arguments.contains("--ui-test-data") else { return }
        #if DEBUG
        let path: String
        if let environmentPath {
            guard arguments.count == 1 else { throw StoreError.invalidInput }
            path = environmentPath
        } else {
            guard arguments.count == 3, arguments[1] == "--ui-test-data" else { throw StoreError.invalidInput }
            path = arguments[2]
        }
        support = try UITestStorage.validatedDirectory(path)
        isUITest = true
        #else
        throw StoreError.invalidInput
        #endif
    }
}
