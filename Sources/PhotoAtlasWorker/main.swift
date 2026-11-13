import Foundation
import AtlasCore

@main
struct PhotoAtlasWorker {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 3 else { exit(2) }
        let database = URL(fileURLWithPath: args[2])
        if args[1] == "--supervisor" {
            exit(WorkerSupervisor.run(database: database, executable: URL(fileURLWithPath: args[0])))
        }
        guard args[1] == "--worker" || args[1] == "--database" else { exit(2) }
        exit(await WorkerRunner.run(database: database))
    }
}
