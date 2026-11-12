// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoAtlas",
    platforms: [.macOS(.v13)],
    products: [.library(name: "AtlasCore", targets: ["AtlasCore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AtlasCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PhotosProbe"),
        .executableTarget(name: "PhotoAtlasApp", dependencies: ["AtlasCore"]),
        .executableTarget(name: "LegacyAudit", dependencies: ["AtlasCore"]),
        .executableTarget(name: "OllamaProbe", dependencies: ["AtlasCore"]),
        .executableTarget(name: "WriteUndoProbe", dependencies: ["AtlasCore"]),
        .executableTarget(name: "PhotoAtlasWorker", dependencies: ["AtlasCore"]),
        .executableTarget(name: "PipelineProbe", dependencies: ["AtlasCore"]),
        .executableTarget(name: "MigrationProbe", dependencies: ["AtlasCore"]),
        .executableTarget(name: "PeopleClientProbe", dependencies: ["AtlasCore"]),
        .executableTarget(name: "PeopleWriteProbe", dependencies: ["AtlasCore"]),
        .executableTarget(name: "UIFixtureProbe", dependencies: ["AtlasCore"]),
        .testTarget(name: "AtlasCoreTests", dependencies: ["AtlasCore", "CSQLite"])
    ]
)
