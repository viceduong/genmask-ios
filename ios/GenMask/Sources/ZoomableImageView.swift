import SwiftUI
import UIKit

/**
 * Fullscreen image viewer with pinch-zoom and pan.
 *
 * A `UIScrollView` rather than SwiftUI gestures. SwiftUI's
 * `MagnificationGesture` has to be combined by hand with a drag for panning
 * and with bounds clamping to stop the image being flung off screen, and on
 * iOS 15 the combination fights the sheet's own dismiss gesture. A scroll view
 * already does all of it — momentum, rubber-banding, double-tap zoom and
 * correct behaviour at the edges — and it is what every photo viewer on the
 * platform is built from.
 *
 * It matters here because the whole point of the app is judging a render
 * against a photograph, and that judgement happens at 1:1. A 340pt preview
 * cannot show whether a jaw drifted or a fingernail softened.
 */
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 12
        scroll.minimumZoomScale = 1
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .black
        // The status bar area is already handled by the sheet; insetting again
        // would letterbox the image away from the edges it should reach.
        scroll.contentInsetAdjustmentBehavior = .never

        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        scroll.addSubview(view)
        context.coordinator.imageView = view

        // Double tap to zoom in on the point tapped, and again to fit. This is
        // the gesture people try first on a photo.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let view = context.coordinator.imageView else { return }
        if view.image !== image {
            view.image = image
            scroll.zoomScale = 1
        }
        // Lay out on every pass: the first one happens before the scroll view
        // has a size, so a frame computed then would be zero.
        view.frame = CGRect(origin: .zero, size: scroll.bounds.size)
        scroll.contentSize = scroll.bounds.size
        context.coordinator.centre(in: scroll)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centre(in: scrollView)
        }

        /// Keep the image centred while it is smaller than the viewport.
        /// Without this it sits in the top-left corner as you zoom out, which
        /// reads as a layout bug rather than as zoom.
        func centre(in scrollView: UIScrollView) {
            guard let view = imageView else { return }
            let x = max(0, (scrollView.bounds.width - view.frame.width) / 2)
            let y = max(0, (scrollView.bounds.height - view.frame.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                // Zoom to where the finger landed rather than to the middle.
                let point = gesture.location(in: imageView)
                let scale: CGFloat = 4
                let size = CGSize(width: scroll.bounds.width / scale,
                                  height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2,
                                       y: point.y - size.height / 2,
                                       width: size.width, height: size.height),
                            animated: true)
            }
        }
    }
}

/**
 * The viewer as a sheet: one image, or two to flip between.
 *
 * When both are supplied the comparison survives zooming — the zoom level and
 * the position are the scroll view's, not the image's, so switching between
 * render and original keeps you on the same pixels. That is the only way to
 * compare a detail honestly.
 */
struct FullscreenImageView: View {
    let result: UIImage
    let plate: UIImage?
    let title: String

    @Environment(\.presentationMode) private var presentation
    @State private var showingPlate = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            ZoomableImage(image: showingPlate ? (plate ?? result) : result)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Text(plate == nil ? title : (showingPlate ? "Original" : "Render"))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.55)))

                    Spacer()

                    Button {
                        presentation.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                }
                .padding()

                Spacer()

                if plate != nil {
                    // Switching at the bottom, where a thumb already is.
                    Picker("", selection: $showingPlate) {
                        Text("Render").tag(false)
                        Text("Original").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    .background(Color.black.opacity(0.35))
                }
            }
        }
    }
}
