import Foundation
import Vision
import ImageIO

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum Ollama {
    public static func request(image: Data) throws -> URLRequest {
        guard !image.isEmpty, image.count <= 8_000_000 else { throw StoreError.invalidInput }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "description": ["type": "string"],
                "keywords": ["type": "array", "items": ["type": "string"]],
                "category": ["type": "string"],
                "sensitive": ["type": "boolean"]
            ],
            "required": ["description", "keywords", "category", "sensitive"]
        ]
        let prompt = "根据照片实际可见内容生成简体中文说明和5至10个简洁关键词。照片包含文字时，尽可能准确识别并在说明中写出可见的重要文字，证件、医疗、金融等敏感文字也要识别。不要猜测看不清的文字、姓名、位置、身份或诊断。证件、医疗、金融或隐私文档标记 sensitive=true。返回 JSON：description、keywords、category、sensitive。"
        let payload: [String: Any] = [
            "model": "qwen3-vl:4b-instruct", "stream": false, "think": false,
            "messages": [["role": "user", "content": prompt, "images": [image.base64EncodedString()]]],
            "format": schema,
            "options": ["temperature": 0, "num_ctx": 4096, "num_predict": 384, "num_thread": 4]
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 200
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    public static func parseResponse(_ data: Data) throws -> AIResult {
        struct Message: Decodable { let content: String }
        struct Response: Decodable { let message: Message }
        let content = try JSONDecoder().decode(Response.self, from: data).message.content
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidInput }
        return try AIResult.parse(content)
    }

    public static func infer(image: Data) async throws -> AIResult {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(image: image))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let result = try parseResponse(data)
        let lines = await Task.detached(priority: .utility) { recognizedText(in: image) }.value
        guard !lines.isEmpty else { return result }
        let text = lines.joined(separator: "\n")
        var keywords = result.keywords
        for line in lines {
            var remaining = line[...]
            while !remaining.isEmpty {
                let end = remaining.index(remaining.startIndex, offsetBy: 60, limitedBy: remaining.endIndex) ?? remaining.endIndex
                let word = String(remaining[..<end])
                if !keywords.contains(word) { keywords.append(word) }
                remaining = remaining[end...]
            }
        }
        return AIResult(description: result.description + "\n照片文字：\n" + text,
                        keywords: keywords, sensitive: result.sensitive, category: result.category)
    }

    static func recognizedText(in image: Data) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(data: image)
        guard (try? handler.perform([request])) != nil else { return [] }
        var remaining = 2000
        var lines: [String] = []
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, remaining > 0 else { continue }
            let line = String(text.prefix(remaining))
            lines.append(line)
            remaining -= line.count
        }
        return lines
    }
}
