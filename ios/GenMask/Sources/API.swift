import Foundation
import UIKit

/// What the server knows about a plate, after it has been uploaded.
struct Plate: Equatable {
    let id: String
    let width: Int
    let height: Int

    var size: CGSize { CGSize(width: width, height: height) }
}

/// One automatic mask, with the server's own description of what editing
/// through it can and cannot do. The text comes from the server rather than
/// being duplicated here, because the aperture's behaviour is a property of the
/// pipeline, not of the app.
struct Aperture: Equatable, Identifiable {
    let name: String
    let url: String
    let description: String

    var id: String { name }

    /// Short label for the picker; the full sentence goes underneath.
    var title: String {
        switch name {
        case "garment": return "Clothes"
        case "body": return "Body"
        case "person": return "Person"
        default: return name.capitalized
        }
    }
}

struct AutomaskResult: Equatable {
    let apertures: [Aperture]
    let overlayPath: String?
}

enum JobMode: String, Equatable, CaseIterable {
    /// Repaint inside a mask; everything outside it is the photograph's own
    /// pixels, composited back untouched.
    case inpaint
    /// Regenerate the whole frame. No mask, nothing preserved by construction.
    case full
}

enum JobStage: String, Equatable {
    case queued, masks, render, done, error, cancelled

    var label: String {
        switch self {
        case .queued: return "Waiting"
        case .masks: return "Finding the subject"
        case .render: return "Rendering"
        case .done: return "Done"
        case .error: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/**
 * The server's HTTP surface, as the app sees it.
 *
 * Deliberately thin: it uploads a photo, asks for masks, hands back a painted
 * one, starts a job and fetches the result. Every rendering decision belongs to
 * the host, so there is nothing here that configures the model.
 */
final class API {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String) {
        // Strip trailing slashes before storing. `appendingPathComponent` does
        // not collapse them, so a host typed as "https://example.com/" becomes
        // "https://example.com//api/plates" -- and a double slash does not
        // reach the origin through Cloudflare, which answers "error code: 1033"
        // as plain text. The app then fails to parse it as JSON and reports a
        // malformed reply, which points at the server rather than at the one
        // character that caused it.
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        self.baseURL = URL(string: text) ?? baseURL
        self.token = token
        let configuration = URLSessionConfiguration.default
        // A 2 MP render is minutes, and the phone may be the only thing
        // waiting on it; the default 60 s would abandon a job mid-flight.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 1800
        configuration.waitsForConnectivity = true
        // Cloudflare advertises HTTP/3 (`alt-svc: h3`), and URLSession will
        // move to QUIC on a later connection once it has seen that header.
        // On iOS 15 that path fails for multipart uploads with
        // NSURLErrorCannotParseResponse (-1017) -- which surfaces as "cannot
        // parse response" and reads like a malformed body rather than a
        // transport problem. The first request succeeds over HTTP/2, so the
        // symptom is a connection that works until it is reused.
        if #available(iOS 15.0, *) {
            configuration.assumesHTTP3Capable = false
        }
        self.session = URLSession(configuration: configuration)
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func check(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "Not an HTTP response")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            if let detail = json?["error"] as? String {
                throw APIError(message: "\(http.statusCode): \(detail)")
            }
            throw APIError(message: "HTTP \(http.statusCode). \(Self.snippet(data))")
        }
        guard let json else {
            // 2xx with a body we cannot read means something answered that is
            // not the server: name the content type and show the start of it,
            // because that is what identifies the interloper.
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? "no content type"
            throw APIError(message: "Reply was not JSON (\(type), \(data.count) bytes). \(Self.snippet(data))")
        }
        return json
    }

    /// First line or so of a response body, for an error message.
    private static func snippet(_ data: Data) -> String {
        guard !data.isEmpty else { return "Empty reply." }
        let text = String(decoding: data.prefix(300), as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Unreadable reply." : String(text.prefix(220))
    }

    /// Reachability and whether the host's ComfyUI is actually up — the two
    /// failures need different fixes, so the app reports them separately.
    func health() async throws -> (comfy: Bool, queue: Int) {
        var request = self.request("api/health")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        let json = try check(data, response)
        return (json["comfy"] as? Bool ?? false, json["queue"] as? Int ?? 0)
    }

    /// Upload a photo as JPEG.
    ///
    /// JPEG rather than the original asset: HEIC is what a modern iPhone
    /// stores, and the host pipeline reads plates with OpenCV, which cannot
    /// open it. Transcoding here means the phone's camera roll works as-is.
    func uploadPlate(_ image: UIImage) async throws -> Plate {
        guard let jpeg = image.jpegData(compressionQuality: 0.95) else {
            throw APIError(message: "Could not encode the photo")
        }
        var request = self.request("api/plates", method: "POST")
        let boundary = "genmask.\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = Self.multipart(boundary: boundary, name: "file",
                                   filename: "plate.jpg", mime: "image/jpeg", payload: jpeg)
        // upload(for:from:) rather than setting httpBody: a multi-megabyte
        // photo is streamed instead of being held in the request, and an
        // explicit length keeps the transfer from being sent chunked.
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.upload(for: request, from: body)
        let json = try check(data, response)
        guard let id = json["id"] as? String,
              let width = json["width"] as? Int,
              let height = json["height"] as? Int else {
            throw APIError(message: "Upload reply was missing id/width/height: \(json)")
        }
        return Plate(id: id, width: width, height: height)
    }

    /// Run the segmentation that derives the aperture family. Minutes is
    /// possible on a cold host, so this is never called on a view appearing —
    /// only when the person asks for automatic masking.
    func automask(plate: Plate) async throws -> AutomaskResult {
        var request = self.request("api/plates/\(plate.id)/automask", method: "POST")
        request.timeoutInterval = 600
        let (data, response) = try await session.data(for: request)
        let json = try check(data, response)
        let raw = json["apertures"] as? [[String: Any]] ?? []
        let apertures: [Aperture] = raw.compactMap { entry in
            guard let name = entry["name"] as? String, let url = entry["url"] as? String else { return nil }
            return Aperture(name: name, url: url, description: entry["description"] as? String ?? "")
        }
        guard !apertures.isEmpty else {
            throw APIError(message: "The host found no person in this photo")
        }
        return AutomaskResult(apertures: apertures, overlayPath: json["overlayUrl"] as? String)
    }

    /// Upload a painted mask. It must already be at plate resolution — the
    /// server rejects anything else, because a mask that does not register
    /// with the plate would silently edit the wrong pixels.
    func uploadManualMask(plate: Plate, png: Data) async throws {
        var request = self.request("api/plates/\(plate.id)/mask", method: "PUT")
        let boundary = "genmask.\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = Self.multipart(boundary: boundary, name: "file",
                                   filename: "mask.png", mime: "image/png", payload: png)
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.upload(for: request, from: body)
        _ = try check(data, response)
    }

    /// Start a job. `mask` is an aperture name or "manual" for inpainting, and
    /// is ignored for a full-frame render.
    func createJob(plate: Plate, prompt: String, mode: JobMode, mask: String?) async throws -> String {
        var request = self.request("api/jobs", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["plateId": plate.id, "prompt": prompt, "mode": mode.rawValue]
        if mode == .inpaint, let mask { body["mask"] = mask }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let json = try check(data, response)
        guard let id = json["id"] as? String else {
            throw APIError(message: "Server did not return a job id")
        }
        return id
    }

    /// Fetch any image the server serves (plate, mask, overlay, result).
    func image(path: String) async throws -> UIImage {
        let url = path.hasPrefix("/")
            ? baseURL.appendingPathComponent(String(path.dropFirst()))
            : baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(message: "Could not load the image")
        }
        guard let image = UIImage(data: data) else {
            throw APIError(message: "Server returned something that is not an image")
        }
        return image
    }

    func eventsURL(jobId: String) -> URL {
        baseURL.appendingPathComponent("api/jobs/\(jobId)/events")
    }

    var bearer: String { token }

    private static func multipart(boundary: String, name: String, filename: String,
                                  mime: String, payload: Data) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
            .data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(payload)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
