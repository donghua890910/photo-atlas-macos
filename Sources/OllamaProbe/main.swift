import Foundation
import AtlasCore

@main
struct OllamaProbe {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("请提供本地测试图片路径。\n", stderr)
            exit(2)
        }
        do {
            let image = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let started = Date()
            let result = try await Ollama.infer(image: image)
            print("推理完成，用时 \(Int(Date().timeIntervalSince(started))) 秒，关键词 \(result.keywords.count) 个，敏感标记 \(result.sensitive)。")
        } catch {
            fputs("本地推理验证失败：\(type(of: error))\n", stderr)
            exit(1)
        }
    }
}
