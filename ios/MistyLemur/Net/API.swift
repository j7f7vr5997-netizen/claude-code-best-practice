import Foundation

/// Thin client for the Fastify domain service + Supabase Auth.
/// Actual wire calls are stubbed — the shape is what matters here.
public final class API {

    public struct Env {
        public let baseURL: URL            // Fastify service (Fly.io)
        public let supabaseURL: URL        // Supabase project (for Storage)
        public let supabaseAnonKey: String
    }

    // In production these come from xcconfig / build settings.
    public let env: Env
    public var sessionToken: String?

    public init(env: Env = .default) { self.env = env }

    // MARK: - Auth

    public func requestOTP(phone: String) async throws {}
    public func verifyOTP(phone: String, code: String) async throws -> String {
        // Return user id on success. Persist sessionToken to Keychain.
        ""
    }
    public func restoreStoredSession() -> String? { nil }
    public func clearSession() { sessionToken = nil }

    // MARK: - Messages

    public func sendMessage(videoURL: URL, signature: Signature) async throws {
        // 1. Upload video.mp4 + signature.json via Storage helper.
        // 2. POST /messages with the resulting URLs + signature.durationMs.
    }

    public func fetchInbox() async throws -> [InboxMessage] { [] }
    public func fetchSignature(messageId: String) async throws -> Signature {
        throw URLError(.unknown)
    }

    public func submitResponse(
        messageId: String,
        videoURL: URL,
        signature: Signature,
        zoomActual: [ZoomCurve.Point],
        clientScore: MatchResult
    ) async throws {
        // POST /messages/:id/attempt → server re-runs FastDTW + zoom RMS,
        // then on pass: marks recipient unlocked+responded and notifies sender.
    }
}

public extension API.Env {
    static let `default` = API.Env(
        baseURL: URL(string: "https://api.mistylemur.app")!,
        supabaseURL: URL(string: "https://example.supabase.co")!,
        supabaseAnonKey: ""
    )
}
