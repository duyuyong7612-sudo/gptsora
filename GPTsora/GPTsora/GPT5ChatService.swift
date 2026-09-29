// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-26ac7cbf4827056303b076dceb1381d9deb9153a39829a57f0f023c1662b538d"
// Source-SHA256: "af6b6fcdbd57c6dffdf26fa3f394e870c9469eb523cf8bd28ddab1a7be62dc67"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

/// Minimal Responses API streaming client.
/// Uses SSE (Server-Sent Events) and yields `ChatResult` deltas.
///
/// Official streaming event `type` values include:
/// - response.output_text.delta
/// - response.reasoning_text.delta
/// - response.output_audio_transcript.delta
/// - response.completed
public final class GPT5ChatService: @unchecked Sendable {
    public enum ServiceError: Error, LocalizedError {
        case badStatus(Int, String)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .badStatus(let code, let msg): return "HTTP \(code): \(msg)"
            case .invalidResponse: return "Invalid response"
            }
        }
    }

    private let config: OpenAIConfig
    private let session: URLSession

    public init(config: OpenAIConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func stream(messages: [LLMMessage]) -> AsyncThrowingStream<ChatResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = config.baseURL.appendingPathComponent("responses")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let input = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
                    let body: [String: Any] = [
                        "model": config.chatModel,
                        "stream": true,
                        "input": input
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await session.bytes(for: req)

                    guard let http = resp as? HTTPURLResponse else {
                        throw ServiceError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Try read some bytes for message
                        var prefix = ""
                        for try await line in bytes.lines {
                            prefix += line
                            if prefix.count > 1000 { break }
                        }
                        throw ServiceError.badStatus(http.statusCode, prefix)
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)

                        if payload == "[DONE]" {
                            continuation.yield(ChatResult(isDone: true))
                            continuation.finish()
                            return
                        }

                        guard let data = payload.data(using: .utf8) else { continue }
                        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        guard let type = obj["type"] as? String else { continue }

                        switch type {
                        case "response.output_text.delta":
                            if let delta = obj["delta"] as? String, !delta.isEmpty {
                                continuation.yield(ChatResult(deltaText: delta))
                            }
                        case "response.reasoning_text.delta":
                            if let delta = obj["delta"] as? String, !delta.isEmpty {
                                continuation.yield(ChatResult(deltaReasoning: delta))
                            }
                        case "response.output_audio_transcript.delta":
                            if let delta = obj["delta"] as? String, !delta.isEmpty {
                                continuation.yield(ChatResult(deltaAudioTranscript: delta))
                            }
                        case "response.completed":
                            continuation.yield(ChatResult(isDone: true))
                            continuation.finish()
                            return
                        case "error":
                            let msg = (obj["message"] as? String) ?? "Unknown error"
                            continuation.yield(ChatResult(isDone: true, error: msg))
                            continuation.finish()
                            return
                        default:
                            // ignore other event types
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

