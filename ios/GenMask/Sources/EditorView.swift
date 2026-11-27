import SwiftUI
import UIKit

/// The whole app, in one screen: a photo, a mask, a prompt, a result.
///
/// One screen rather than a wizard because the three choices interact — the
/// aperture decides what the prompt is able to do, and a prompt that moves the
/// body against a clothes-only mask does nothing at all. Putting them side by
/// side is what makes that visible.
struct EditorView: View {
    @StateObject private var model = EditorViewModel()

    /// Which sheet is up.
    ///
    /// One `.sheet(item:)` rather than three `.sheet(isPresented:)` modifiers:
    /// stacking them on the same view is silently lossy -- SwiftUI honours only
    /// one, so the photo picker and Settings simply never appeared while the
    /// result sheet worked. Carrying the picker's source in the case also fixes
    /// a staleness bug, because a `.sheet(isPresented:)` closure captures the
    /// surrounding @State when the sheet is built, not when it opens.
    private enum Route: Identifiable {
        case picker(UIImagePickerController.SourceType)
        case settings
        case result

        var id: String {
            switch self {
            case .picker(let source): return "picker-\(source.rawValue)"
            case .settings: return "settings"
            case .result: return "result"
            }
        }
    }

    @State private var route: Route?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    plateSection
                    if model.plate != nil {
                        maskSection
                        promptSection
                        submitSection
                    }
                    if model.plateImage != nil && model.plate == nil
                        && !model.isBusy && model.errorMessage == nil {
                        Text("The photo did not upload. Check the server address and token in Settings, then pick it again.")
                            .font(.footnote)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let error = model.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationBarTitle("GenMask", displayMode: .inline)
            .navigationBarItems(trailing: Button {
                route = .settings
            } label: {
                Image(systemName: "gearshape")
            })
            .sheet(item: $route) { route in
                switch route {
                case .picker(let source):
                    ImagePicker(source: source) { image in
                        // Not `Task { ... }` here: this closure runs as the
                        // picker dismisses, and a task created in the sheet's
                        // own view tree is cancelled when that tree goes away.
                        model.accept(image: image)
                    }
                case .settings:
                    SettingsView(model: model)
                case .result:
                    if let result = model.result, let plate = model.plateImage {
                        ResultView(plate: plate, result: result)
                    }
                }
            }
            .onChange(of: model.result) { value in
                if value != nil { route = .result }
            }
        }
        .navigationViewStyle(.stack)
        .task { await model.checkHost() }
    }

    // MARK: Plate

    private var plateSection: some View {
        VStack(spacing: 12) {
            if let plateImage = model.plateImage {
                maskPreview(plateImage)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                    .foregroundColor(.secondary)
                    .frame(height: 220)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
                            Text("Choose a photo to edit").font(.subheadline)
                        }
                        .foregroundColor(.secondary)
                    )
            }

            HStack(spacing: 12) {
                Button {
                    route = .picker(.photoLibrary)
                } label: {
                    Label("Photo", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        route = .picker(.camera)
                    } label: {
                        Label("Camera", systemImage: "camera").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if model.plateImage != nil && model.plate == nil && model.isBusy {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Uploading the photo…").font(.caption)
                }
                .foregroundColor(.secondary)
            }

            if let status = model.hostStatus {
                Text(status)
                    .font(.caption)
                    .foregroundColor(model.hostReady ? .secondary : .orange)
            }
        }
    }

    /// The plate with whatever mask is current drawn over it. In manual mode
    /// this is the painting surface; otherwise it is a read-only preview of the
    /// aperture, which is the only way to see what an aperture actually covers.
    @ViewBuilder
    private func maskPreview(_ plateImage: UIImage) -> some View {
        let size = model.plate?.size ?? plateImage.size
        ZStack {
            if model.maskChoice == .manual {
                MaskCanvas(plate: plateImage, plateSize: size,
                           drawing: $model.drawing,
                           brushWidth: $model.brushWidth,
                           erasing: $model.erasing)
            } else {
                GeometryReader { geometry in
                    let frame = MaskCanvas.fittedRect(content: size, in: geometry.size)
                    ZStack {
                        Image(uiImage: plateImage).resizable()
                            .frame(width: frame.width, height: frame.height)
                        if case .aperture(let name)? = model.maskChoice,
                           let mask = model.apertureMasks[name] {
                            Image(uiImage: mask).resizable()
                                .frame(width: frame.width, height: frame.height)
                                .blendMode(.screen)
                                .opacity(0.45)
                                .colorMultiply(.red)
                        }
                    }
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(height: 340)
        .background(Color.black.opacity(0.04))
        .cornerRadius(12)
    }

    // MARK: Mask

    private var maskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mask").font(.headline)

            if model.mode == .full {
                Text("A full-frame render regenerates the whole picture, so it uses no mask. The background and the pose are not preserved.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack {
                    Button {
                        Task { await model.runAutomask() }
                    } label: {
                        if model.isSegmenting {
                            HStack(spacing: 6) {
                                ProgressView()
                                Text("Finding the subject…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Automatic", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isSegmenting)

                    Button {
                        model.startManualMask(fromCurrentAperture: !model.apertures.isEmpty)
                    } label: {
                        Label("Paint", systemImage: "paintbrush.pointed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if !model.apertures.isEmpty {
                    Picker("Aperture", selection: Binding(
                        get: {
                            if case .aperture(let name)? = model.maskChoice { return name }
                            return ""
                        },
                        set: { model.select(aperture: $0) }
                    )) {
                        ForEach(model.apertures) { aperture in
                            Text(aperture.title).tag(aperture.name)
                        }
                    }
                    .pickerStyle(.segmented)

                    if case .aperture(let name)? = model.maskChoice,
                       let aperture = model.apertures.first(where: { $0.name == name }) {
                        Text(aperture.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if model.maskChoice == .manual {
                    manualControls
                }
            }
        }
    }

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $model.erasing) {
                    Text("Brush").tag(false)
                    Text("Eraser").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)

                Spacer()

                Button { model.drawing.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(model.drawing.strokes.isEmpty)

                Button { model.drawing.clear() } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.drawing.isEmpty)
            }

            HStack(spacing: 8) {
                Image(systemName: "circle.fill").font(.system(size: 8)).foregroundColor(.secondary)
                Slider(value: $model.brushWidth, in: 0.01...0.25)
                Image(systemName: "circle.fill").font(.system(size: 20)).foregroundColor(.secondary)
            }

            Text("Paint over everything the edit is allowed to change. Anything you leave unpainted is kept exactly as photographed.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt").font(.headline)

            // iOS 15 has no multi-line TextField(axis:), so the editor is a
            // TextEditor with a fixed height.
            TextEditor(text: $model.prompt)
                .frame(height: 110)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

            Picker("Mode", selection: $model.mode) {
                Text("Inpaint").tag(JobMode.inpaint)
                Text("Full frame").tag(JobMode.full)
            }
            .pickerStyle(.segmented)

            Text(model.mode == .inpaint
                 ? "Only the masked pixels are repainted; everything else is the photograph."
                 : "The whole frame is generated again. Use it when the picture should change, not just a region.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Submit

    private var submitSection: some View {
        VStack(spacing: 10) {
            if model.isBusy, model.stage != nil {
                VStack(spacing: 6) {
                    ProgressView(value: model.progress)
                    HStack {
                        Text(model.statusText).font(.caption)
                        Spacer()
                        Button("Stop watching") { model.cancelWatching() }
                            .font(.caption)
                    }
                }
            }

            Button {
                Task { await model.submit() }
            } label: {
                Text(model.isBusy ? "Working…" : "Generate")
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSubmit)

            if model.result != nil {
                Button("Show result") { route = .result }
                    .font(.subheadline)
            }
        }
    }
}

/// Settings: the host and its token, nothing else. The render regime is the
/// host's business and is deliberately not exposed.
struct SettingsView: View {
    @ObservedObject var model: EditorViewModel
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Host")) {
                    TextField("https://gen.2031.lol", text: $model.serverURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    SecureField("Access token", text: $model.token)
                }
                Section {
                    Button("Test connection") {
                        model.saveConnection()
                        Task { await model.checkHost() }
                    }
                    if let status = model.hostStatus {
                        Text(status).font(.caption).foregroundColor(.secondary)
                    }
                }
                Section(footer: Text("Rendering happens on your own machine. The app sends the photo, the mask and the prompt, and nothing else.")) {
                    EmptyView()
                }
            }
            .navigationBarTitle("Settings", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                model.saveConnection()
                presentation.wrappedValue.dismiss()
            })
        }
        .navigationViewStyle(.stack)
    }
}
