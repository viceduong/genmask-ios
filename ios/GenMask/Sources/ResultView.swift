import Photos
import SwiftUI
import UIKit

/// The render, against the photograph it came from.
///
/// Before/after rather than the result alone: the question a masked edit raises
/// is always "what else moved?", and that is only answerable by comparison. The
/// toggle holds the same frame so switching between them does not also change
/// the zoom or the position.
struct ResultView: View {
    let plate: UIImage
    let result: UIImage

    @Environment(\.presentationMode) private var presentation
    @State private var showingPlate = false
    @State private var saveMessage: String?
    @State private var fullscreen = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Image(uiImage: showingPlate ? plate : result)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .background(Color.black.opacity(0.04))
                    .cornerRadius(12)
                    // A press-and-hold is the fastest before/after there is:
                    // it flips while held and flips back on release.
                    //
                    // DragGesture(minimumDistance: 0) rather than
                    // onLongPressGesture: the long-press `pressing` callback
                    // goes false as soon as the press *succeeds*, so with a
                    // short minimumDuration the image flipped back while the
                    // finger was still down -- it looked like nothing worked.
                    // A zero-distance drag tracks the finger itself: onChanged
                    // for down, onEnded for up.
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !showingPlate { showingPlate = true }
                            }
                            .onEnded { _ in showingPlate = false }
                    )
                    // Tap for fullscreen. A render is judged at 1:1 -- whether
                    // a jaw drifted or a nail softened is invisible at preview
                    // size -- so the viewer is the point, not a nicety.
                    .onTapGesture { fullscreen = true }

                // A plain toggle as well as the hold: holding is quicker for
                // a glance, but a locked comparison is what you want when
                // looking closely at one region.
                Picker("", selection: $showingPlate) {
                    Text("Render").tag(false)
                    Text("Original").tag(true)
                }
                .pickerStyle(.segmented)

                Text(showingPlate
                     ? "Showing the original photo"
                     : "Tap to open fullscreen, or press and hold to compare")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let saveMessage {
                    Text(saveMessage).font(.caption).foregroundColor(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        save()
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.bottom)
            }
            .padding()
            .fullScreenCover(isPresented: $fullscreen) {
                FullscreenImageView(result: result, plate: plate, title: "Render")
            }
            .navigationBarTitle("Result", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                presentation.wrappedValue.dismiss()
            })
        }
        .navigationViewStyle(.stack)
    }

    /// Save with an explicit add-only authorisation request.
    ///
    /// `.addOnly` rather than full access: the app only ever writes, and asking
    /// for read access to the whole library to save one file is more permission
    /// than the feature needs.
    private func save() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    saveMessage = "Photos access was declined, so the render was not saved."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: result)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    saveMessage = success
                        ? "Saved to Photos."
                        : (error?.localizedDescription ?? "Could not save the render.")
                }
            }
        }
    }
}

/// `UIImagePickerController` wrapper.
///
/// Not `PhotosPicker`: that is iOS 16, and the deployment target here is 15.0
/// so the app runs on an older device. The picker also gives the camera for
/// free, which is the other way a plate arrives.
struct ImagePicker: UIViewControllerRepresentable {
    let source: UIImagePickerController.SourceType
    let onPick: (UIImage) -> Void

    @Environment(\.presentationMode) private var presentation

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = source
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: ImagePicker

        init(_ parent: ImagePicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.presentation.wrappedValue.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentation.wrappedValue.dismiss()
        }
    }
}
