import Foundation
import XCTest
import AppKit
@testable import AtlasCore

final class OllamaTests: XCTestCase {
    func testRequestTargetsLocalInstructModelAndLimitsOutput() throws {
        let request = try Ollama.request(image: Data([1, 2, 3]))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "qwen3-vl:4b-instruct")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["think"] as? Bool, false)
        let options = try XCTUnwrap(json["options"] as? [String: Int])
        XCTAssertEqual(options["num_ctx"], 4096)
        XCTAssertLessThanOrEqual(options["num_predict"] ?? .max, 512)
    }
    func testResultParsesStringKeywords() throws {
        let content = #"{"description":"海边的落日","keywords":"海边，夕阳","sensitive":false}"#
        let payload = try JSONSerialization.data(withJSONObject: ["message": ["content": content]])
        XCTAssertEqual(try Ollama.parseResponse(payload).keywords, ["海边", "夕阳"])
    }
    func testRejectsEmptyImageAndEmptyResponse() throws {
        XCTAssertThrowsError(try Ollama.request(image: Data()))
        let payload = try JSONSerialization.data(withJSONObject: ["message": ["content": ""]])
        XCTAssertThrowsError(try Ollama.parseResponse(payload))
    }

    func testRecognizesTextInDocumentImage() throws {
        let image = NSImage(size: NSSize(width: 900, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 200).fill()
        ("Invoice 12345" as NSString).draw(at: NSPoint(x: 30, y: 70), withAttributes: [
            .font: NSFont.systemFont(ofSize: 70), .foregroundColor: NSColor.black
        ])
        image.unlockFocus()
        let data = try XCTUnwrap(image.tiffRepresentation)
        XCTAssertTrue(try Ollama.recognizedText(in: data).joined().contains("12345"))
    }
}
