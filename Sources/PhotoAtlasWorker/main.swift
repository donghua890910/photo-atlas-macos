import Foundation
import AtlasCore

@main
struct PhotoAtlasWorker {
    static func main() async {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--database" else { exit(2) }
        exit(await WorkerRunner.run(database: URL(fileURLWithPath: CommandLine.arguments[2])))
    }
}
