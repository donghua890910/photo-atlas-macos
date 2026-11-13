import Foundation
import AppKit
import SwiftUI
import AtlasCore

@main
struct Launcher {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        do { try AppEnvironment.configure(arguments: args) }
        catch { fputs("测试数据目录无效或当前构建不支持测试模式。\n", stderr); exit(2) }
        #if DEBUG
        if args.count == 3 && args[1] == "--people-probe" {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = object["asset_id"] as? String, let resource = Bundle.main.resourceURL else { exit(2) }
                let python = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AI-Photo-Manager/.venv/bin/python")
                let client = PeopleClient(executable: python, script: resource.appendingPathComponent("people_index.py"))
                let first = try await client.names(for: id)
                let second = try await client.names(for: id)
                await client.stop()
                guard first == second, !first.isEmpty else { exit(3) }
                print("应用进程人物索引查询成功，重复结果一致，姓名数量：\(first.count)。")
                exit(0)
            } catch { fputs("应用进程无法读取人物索引。\n", stderr); exit(1) }
        }
        #endif
        if args.count == 3 && args[1] == "--supervisor" {
            NSApplication.shared.setActivationPolicy(.prohibited)
            guard let executable = Bundle.main.executableURL else { exit(3) }
            exit(WorkerSupervisor.run(database: URL(fileURLWithPath: args[2]), executable: executable))
        }
        if args.count == 3 && args[1] == "--worker" {
            NSApplication.shared.setActivationPolicy(.prohibited)
            exit(await WorkerRunner.run(database: URL(fileURLWithPath: args[2])))
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            let pid = ProcessInfo.processInfo.processIdentifier
            let anotherWindowApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                $0.processIdentifier != pid && !$0.isTerminated && $0.activationPolicy != .prohibited
            }
            if let anotherWindowApp {
                if anotherWindowApp.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
                    anotherWindowApp.activate()
                    return
                }
                VersionConflictApp.main()
                return
            }
        }
        PhotoAtlasApp.main()
    }
}

private struct VersionConflictApp: App {
    var body: some Scene {
        WindowGroup("Photo Atlas") {
            VStack(alignment: .leading, spacing: 14) {
                Label("另一个 Photo Atlas 版本正在运行", systemImage: "exclamationmark.circle")
                    .font(.headline)
                Text("请切换到已打开的版本，按 ⌘Q 退出，然后重新打开这个版本。")
                    .foregroundStyle(.secondary)
                Button("关闭") { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
            .frame(width: 420, alignment: .leading)
        }
        .windowResizability(.contentSize)
    }
}
