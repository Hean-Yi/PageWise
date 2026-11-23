import Foundation
import Testing

@testable import PaperReaderKit

@Test(arguments: ModelServicePreset.allCases.filter { $0 != .custom })
func presetRecognizesExistingFullEndpointWithoutChangingTheSavedModel(_ preset: ModelServicePreset) throws {
    var saved = ModelSettings()
    saved.model = "account-specific-version"
    saved.baseURL = preset.baseURL + "/chat/completions/"
    #expect(ModelServicePreset.matching(saved) == preset)
    #expect(try saved.normalized().model == "account-specific-version")
    saved.baseURL = preset.baseURL + "/other"
    #expect(ModelServicePreset.matching(saved) == .custom)
}

private actor PresetTransport: HTTPTransport {
    var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: String
        if request.value(forHTTPHeaderField: "Accept") == "text/event-stream" {
            let delta = #"{"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}"#
            body = "data: " + delta + "\n\ndata: [DONE]\n\n"
        } else {
            body = #"{"choices":[{"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}"#
        }
        return (
            Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test(arguments: ModelServicePreset.allCases.filter { $0 != .custom })
func modelServicesUseTheirWireFormatForTextReflowAndTools(_ preset: ModelServicePreset) async throws {
    let transport = PresetTransport()
    let client = ModelClient(transport: transport)
    var settings = ModelSettings()
    settings.baseURL = preset.baseURL
    settings.model = preset.defaultModel
    _ = try await client.complete(settings: settings, key: "fixture", system: "JSON", user: "test", jsonOutput: true)
    _ = try await client.completeStream(
        settings: settings, key: "fixture", maxOutputTokens: 8192, system: "JSON", user: "test", reflow: true
    ) { _ in }
    _ = try await AgentClient(transport: transport).respondStreaming(
        settings: settings, key: "fixture", messages: [.init(role: "user", content: "test")], limits: .init()
    ) { _ in }
    let requests = await transport.requests
    #expect(requests.count == 3)
    for (index, request) in requests.enumerated() {
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request.url?.absoluteString == preset.baseURL + "/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(body["model"] as? String == preset.defaultModel)
        let modernLimit = preset == .openAI || preset == .kimi
        #expect(body[modernLimit ? "max_completion_tokens" : "max_tokens"] as? Int == (index == 1 ? 8192 : 4096))
        #expect(body[modernLimit ? "max_tokens" : "max_completion_tokens"] == nil)
        if [.anthropic, .kimi, .openAI].contains(preset) { #expect(body["temperature"] == nil) }
        if preset == .anthropic || index == 2 {
            #expect(body["response_format"] == nil)
        } else {
            #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        }
    }
}
