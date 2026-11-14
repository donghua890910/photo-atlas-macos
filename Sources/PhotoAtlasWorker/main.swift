import Foundation
import AtlasCore

@main
struct PhotoAtlasWorker {
    static func main() async {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "--ocr" {
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Recognize text in a user-requested photo scan")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard !input.isEmpty, input.count <= 8_000_000 else { exit(2) }
                let lines = try Ollama.recognizedText(in: input)
                try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(lines))
                exit(0)
            } catch { exit(1) }
        }
        guard args.count == 3 else { exit(2) }
        let database = URL(fileURLWithPath: args[2])
        if args[1] == "--supervisor" {
            exit(WorkerSupervisor.run(database: database, executable: URL(fileURLWithPath: args[0])))
        }
        guard args[1] == "--worker" || args[1] == "--database" else { exit(2) }
        exit(await WorkerRunner.run(database: database))
    }
}
