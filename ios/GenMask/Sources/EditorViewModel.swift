import Foundation
import SwiftUI
import UIKit

/// Which mask an inpaint job should use.
enum MaskChoice: Equatable {
    case aperture(String)
    case manual

    var wireName: String {
        switch self {
        case .aperture(let name): return name
        case .manual: return "manual"
        }
    }
}

/**
 * The editor's state machine.
 *
 * `@MainActor` on the whole type rather than on individual members: every
 * property here feeds the view, and the alternative is a class where some
 * mutations hop actors and the ordering of two updates to the same progress bar
 * depends on which path set it.
 */
@MainActor
final class EditorViewModel: ObservableObject {
    // MARK: Connection

    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? "https://gen.2031.lol"
    @Published var token: String = UserDefaults.standard.string(forKey: "token") ?? ""
    @Published private(set) var hostStatus: String?
    @Published private(set) var hostReady = false

    // MARK: Plate and masks

    @Published var plateImage: UIImage?
    @Published private(set) var plate: Plate?
    @Published private(set) var apertures: [Aperture] = []
    @Published private(set) var apertureMasks: [String: UIImage] = [:]
    @Published var maskChoice: MaskChoice?
    @Published var drawing = MaskDrawing()
    @Published var brushWidth: CGFloat = 0.06
    @Published var erasing = false
    @Published private(set) var isSegmenting = false

    // MARK: Job

    @Published var prompt = ""
    @Published var mode: JobMode = .inpaint
    @Published private(set) var stage: JobStage?
    @Published private(set) var progress: Double = 0
    @Published private(set) var queuePosition: Int?
    @Published private(set) var result: UIImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false

    private var eventSource: EventSource?
    private var currentJob: String?
    /// Retained so the upload survives the picker sheet being dismissed.
    private var uploadTask: Task<Void, Never>?

    private var api: API? {
        // Trailing slashes and a missing scheme are the two things people
        // actually type; both are repaired here rather than rejected.
        var text = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.scheme != nil, !token.isEmpty else { return nil }
        return API(baseURL: url, token: token)
    }

    func saveConnection() {
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        UserDefaults.standard.set(token, forKey: "token")
    }

    /// Reachability check. Reports "no ComfyUI" distinctly from "no server",
    /// because the first is a host the person has to start something on and the
    /// second is an address or token they have to fix.
    func checkHost() async {
        guard let api else {
            hostStatus = "Enter the server address and token"
            hostReady = false
            return
        }
        do {
            let (comfy, queue) = try await api.health()
            hostReady = true
            if !comfy {
                hostStatus = "Host reachable, but ComfyUI is not running"
            } else if queue > 0 {
                hostStatus = "Host ready — \(queue) job\(queue == 1 ? "" : "s") in the queue"
            } else {
                hostStatus = "Host ready"
            }
        } catch {
            hostReady = false
            hostStatus = error.localizedDescription
        }
    }

    // MARK: Plate

    /// Hand a freshly picked photo to the model.
    ///
    /// Synchronous, and it owns the upload task itself, because the caller is
    /// the image picker's completion handler: the picker dismisses as soon as
    /// it fires, and a `Task` started inside that sheet's view hierarchy is
    /// torn down with it -- the upload was cancelled before it could finish,
    /// which is why the photo appeared and nothing else ever did. A task held
    /// here belongs to the view model and outlives the sheet.
    func accept(image: UIImage) {
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            await self?.use(image: image)
        }
    }

    func use(image: UIImage) async {
        // Normalise orientation first. A photo straight from the camera carries
        // its rotation in EXIF, and the host reads pixels: an unrotated upload
        // would be masked and rendered sideways.
        let upright = image.uprighted()
        plateImage = upright
        plate = nil
        apertures = []
        apertureMasks = [:]
        maskChoice = nil
        drawing.clear()
        result = nil
        errorMessage = nil
        stage = nil

        guard let api else {
            errorMessage = "Set the server address and token first"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            plate = try await api.uploadPlate(upright)
        } catch {
            // A silent failure here is exactly what made the app look dead, so
            // cancellation is named rather than left as an opaque message.
            // URLSession reports it as an NSError, not a CancellationError.
            let nsError = error as NSError
            if error is CancellationError ||
                (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                errorMessage = "The upload was cancelled before it finished."
            } else if nsError.domain == NSURLErrorDomain {
                // Carry the numeric code: URLSession's wording for transport
                // faults ("cannot parse response" for -1017) describes the
                // body and hides the fact that it is a connection problem.
                errorMessage = "Network error \(nsError.code): \(nsError.localizedDescription)"
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Automatic masking. Runs the host's segmentation and loads every aperture
    /// it produced, so switching between them afterwards is instant.
    func runAutomask() async {
        guard let api, let plate else { return }
        isSegmenting = true
        errorMessage = nil
        defer { isSegmenting = false }
        do {
            let result = try await api.automask(plate: plate)
            apertures = result.apertures
            var loaded: [String: UIImage] = [:]
            for aperture in result.apertures {
                if let image = try? await api.image(path: aperture.url) {
                    loaded[aperture.name] = MaskRenderer.normalised(image, to: plate.size)
                }
            }
            apertureMasks = loaded
            // Clothes-only is the safe default: it is the one aperture that
            // cannot move the scene or the stance, so an unexpected result is
            // never a surprise about what changed.
            if let first = result.apertures.first(where: { $0.name == "garment" }) ?? result.apertures.first {
                select(aperture: first.name)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(aperture name: String) {
        maskChoice = .aperture(name)
        // Switching aperture discards hand corrections on purpose: they were
        // drawn against a different region, and silently carrying them over
        // would edit pixels the person never painted.
        drawing.strokes.removeAll()
        drawing.baseMask = apertureMasks[name]
    }

    /// Start painting. Keeping the selected aperture as the base is the common
    /// case — correcting a mask that is nearly right beats drawing one.
    func startManualMask(fromCurrentAperture: Bool) {
        if fromCurrentAperture, case .aperture(let name)? = maskChoice {
            drawing.baseMask = apertureMasks[name]
        } else if !fromCurrentAperture {
            drawing.baseMask = nil
        }
        drawing.strokes.removeAll()
        maskChoice = .manual
    }

    var canSubmit: Bool {
        guard plate != nil, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isBusy else {
            return false
        }
        if mode == .full { return true }
        guard let maskChoice else { return false }
        if maskChoice == .manual { return !drawing.isEmpty }
        return true
    }

    func submit() async {
        guard let api, let plate, canSubmit else { return }
        isBusy = true
        errorMessage = nil
        result = nil
        progress = 0
        queuePosition = nil
        stage = .queued

        do {
            // A painted mask is uploaded at plate resolution; the server
            // rejects any other size rather than mis-registering it.
            if mode == .inpaint, maskChoice == .manual {
                guard let png = MaskRenderer.png(from: drawing, plateSize: plate.size) else {
                    throw APIError(message: "Could not build the mask")
                }
                try await api.uploadManualMask(plate: plate, png: png)
            }

            let jobId = try await api.createJob(plate: plate, prompt: prompt, mode: mode,
                                                mask: mode == .inpaint ? maskChoice?.wireName : nil)
            currentJob = jobId
            watch(jobId: jobId, api: api)
        } catch {
            errorMessage = error.localizedDescription
            stage = .error
            isBusy = false
        }
    }

    /// Follow a job over SSE.
    ///
    /// Replay on reconnect is the point: a phone that loses signal mid-render
    /// rejoins and is told what it missed, rather than silently resuming a
    /// stream that looks the same as one that never moved.
    private func watch(jobId: String, api: API) {
        eventSource?.stop()
        let source = EventSource(url: api.eventsURL(jobId: jobId), token: api.bearer)
        source.onFrames = { [weak self] frames in
            guard let self else { return }
            for frame in frames { self.handle(frame, api: api, jobId: jobId) }
        }
        source.onError = { [weak self] message in
            // A dropped stream is not a failed render: the job keeps going on
            // the host, and the reconnect will replay what was missed.
            self?.hostStatus = message
        }
        eventSource = source
        source.start()
    }

    private func handle(_ frame: ParsedSSEFrame, api: API, jobId: String) {
        switch frame.type {
        case "stage":
            if let raw = frame.payload?["stage"] as? String, let parsed = JobStage(rawValue: raw) {
                stage = parsed
                if parsed != .queued { queuePosition = nil }
            }
            if let position = frame.payload?["position"] as? Int { queuePosition = position }
        case "progress":
            if let fraction = frame.payload?["fraction"] as? Double { progress = fraction }
        case "done":
            stage = .done
            progress = 1
            isBusy = false
            eventSource?.stop()
            if let path = frame.payload?["resultUrl"] as? String {
                Task { [weak self] in
                    if let image = try? await api.image(path: path) {
                        self?.result = image
                    } else {
                        self?.errorMessage = "The render finished but the image could not be loaded"
                    }
                }
            }
        case "error":
            stage = .error
            isBusy = false
            errorMessage = (frame.payload?["message"] as? String) ?? "The render failed"
            eventSource?.stop()
        default:
            break
        }
        _ = jobId
    }

    func cancelWatching() {
        eventSource?.stop()
        eventSource = nil
        isBusy = false
    }

    /// What the progress bar should say. A queued job reports its place in line
    /// rather than a frozen zero, because waiting behind someone else's render
    /// is the normal case on a single-GPU host.
    var statusText: String {
        guard let stage else { return "" }
        if stage == .queued, let queuePosition, queuePosition > 0 {
            return "Waiting — \(queuePosition) ahead"
        }
        if stage == .render, progress > 0 {
            return "Rendering \(Int(progress * 100))%"
        }
        return stage.label
    }
}

extension UIImage {
    /// Bake EXIF orientation into the pixels.
    func uprighted() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
