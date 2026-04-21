import Foundation

/// Direct upload/download against Supabase Storage.
/// Short-lived signed URLs are handed out by the Fastify service; this helper
/// just PUTs/GETs the bytes — it never sees the anon key beyond bootstrap.
public enum Storage {

    public struct SignedUpload {
        public let putURL: URL
        public let publicURL: URL
    }

    public static func upload(localFile: URL, to signed: SignedUpload) async throws {
        var req = URLRequest(url: signed.putURL)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: req, fromFile: localFile)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    public static func uploadJSON<T: Encodable>(_ value: T, to signed: SignedUpload) async throws {
        let data = try JSONEncoder().encode(value)
        var req = URLRequest(url: signed.putURL)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: req, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    public static func download(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}
