// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-cd7859971692a17b2bc0ac7c8c7a7cd5e453d5e0e9a7a479948d5f25ae3e1361"
// Source-SHA256: "d3c5da0f750c80f88a2f62f3130d4e359727b5dc4517dbc0cff8869fe478fef3"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

/// Model used for sending history to the Responses API.
public struct LLMMessage: Codable, Sendable, Hashable {
    public var role: ChatRole
    public var content: String

    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// UI message model.
public struct ChatMessage: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var role: ChatRole
    public var fullText: String
    public var displayText: String
    public var isThinking: Bool
    public var isStreaming: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        fullText: String,
        displayText: String? = nil,
        isThinking: Bool = false,
        isStreaming: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.fullText = fullText
        self.displayText = displayText ?? fullText
        self.isThinking = isThinking
        self.isStreaming = isStreaming
        self.createdAt = createdAt
    }
}

/// Minimal attachment model (optional).
public struct ChatAttachment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String
    public var mime: String?
    public var url: String?

    public init(id: String, type: String = "file", mime: String? = nil, url: String? = nil) {
        self.id = id
        self.type = type
        self.mime = mime
        self.url = url
    }
}

/// Streaming delta container returned by GPT5ChatService.
public struct ChatResult: Sendable {
    public var deltaText: String?
    public var deltaReasoning: String?
    public var deltaAudioTranscript: String?
    public var isDone: Bool
    public var error: String?

    public init(
        deltaText: String? = nil,
        deltaReasoning: String? = nil,
        deltaAudioTranscript: String? = nil,
        isDone: Bool = false,
        error: String? = nil
    ) {
        self.deltaText = deltaText
        self.deltaReasoning = deltaReasoning
        self.deltaAudioTranscript = deltaAudioTranscript
        self.isDone = isDone
        self.error = error
    }
}

