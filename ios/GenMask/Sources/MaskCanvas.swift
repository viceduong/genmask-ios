import SwiftUI
import UIKit

/**
 * The painted mask.
 *
 * Strokes are kept as geometry rather than as pixels, for two reasons that
 * matter to the result rather than to the code:
 *
 *   * Undo has to be per-stroke. Painting a mask on a phone is a sequence of
 *     coarse gestures and the fix for a bad one is to take it back, not to
 *     erase over it.
 *   * The mask the server needs is at *plate* resolution, which is several
 *     times the size of the view it was drawn in. Geometry rasterises at any
 *     scale; a bitmap drawn at view scale would have to be upsampled, and a
 *     soft upsampled edge in a binary mask reads as a ragged aperture.
 */
struct MaskStroke: Equatable {
    /// Points in *normalised* plate coordinates (0...1), so the stroke is
    /// independent of the size of the view that captured it.
    var points: [CGPoint]
    /// Brush diameter as a fraction of the plate's larger side, for the same
    /// reason.
    var width: CGFloat
    /// An eraser is a stroke that removes rather than adds.
    var erase: Bool
}

struct MaskDrawing: Equatable {
    var strokes: [MaskStroke] = []
    /// A mask can start from an automatic aperture and be corrected, which is
    /// usually far less work than painting one from nothing. When set, this is
    /// the base the strokes are composited onto.
    var baseMask: UIImage?

    var isEmpty: Bool { strokes.isEmpty && baseMask == nil }

    mutating func undo() {
        if !strokes.isEmpty { strokes.removeLast() }
    }

    mutating func clear() {
        strokes.removeAll()
        baseMask = nil
    }
}

enum MaskRenderer {
    /**
     * Rasterise a drawing to the white-on-black PNG the pipeline expects.
     *
     * Hard-edged on purpose. The host dilates and feathers the mask itself
     * (`--mask-expand 24 --mask-blur 16`), and those values are calibrated; a
     * mask that arrives pre-softened would be feathered twice and the aperture
     * would creep outwards from where it was drawn.
     */
    static func png(from drawing: MaskDrawing, plateSize: CGSize) -> Data? {
        guard plateSize.width > 0, plateSize.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: plateSize, format: format)

        let image = renderer.image { context in
            let cg = context.cgContext
            UIColor.black.setFill()
            cg.fill(CGRect(origin: .zero, size: plateSize))

            // The automatic aperture, when the person started from one.
            if let base = drawing.baseMask, let cgBase = base.cgImage {
                cg.draw(cgBase, in: CGRect(origin: .zero, size: plateSize))
            }

            let reference = max(plateSize.width, plateSize.height)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)

            for stroke in drawing.strokes {
                guard !stroke.points.isEmpty else { continue }
                // Erasing paints black: the mask is a coverage map, so removal
                // is just the absence of coverage, and `.clear` on an opaque
                // context would leave undefined pixels instead.
                cg.setStrokeColor((stroke.erase ? UIColor.black : UIColor.white).cgColor)
                cg.setFillColor((stroke.erase ? UIColor.black : UIColor.white).cgColor)
                cg.setLineWidth(stroke.width * reference)

                let points = stroke.points.map {
                    CGPoint(x: $0.x * plateSize.width, y: $0.y * plateSize.height)
                }
                if points.count == 1 {
                    // A tap is a dot, not a no-op.
                    let radius = stroke.width * reference / 2
                    cg.fillEllipse(in: CGRect(x: points[0].x - radius, y: points[0].y - radius,
                                              width: radius * 2, height: radius * 2))
                } else {
                    cg.beginPath()
                    cg.move(to: points[0])
                    for point in points.dropFirst() { cg.addLine(to: point) }
                    cg.strokePath()
                }
            }
        }

        // A mask has no business being anything but grey; encoding it as one
        // channel keeps the upload small on a phone connection.
        return image.pngData()
    }

    /// Scale a server-sent mask to the plate's exact pixel size, so a mask used
    /// as a painting base composites 1:1 rather than being resampled at draw
    /// time.
    static func normalised(_ mask: UIImage, to plateSize: CGSize) -> UIImage {
        if mask.size == plateSize, mask.scale == 1 { return mask }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: plateSize, format: format).image { _ in
            mask.draw(in: CGRect(origin: .zero, size: plateSize))
        }
    }
}

/**
 * The painting surface.
 *
 * The plate is shown at `.fit` and the gesture is translated into the plate's
 * normalised space, so what is painted lands where it looked like it landed
 * regardless of the device. Drawing happens in a `Canvas`-free way because the
 * deployment target is iOS 15: strokes are composited into a `Path` per stroke
 * and drawn as SwiftUI shapes, which is fast enough for the handful of coarse
 * strokes a mask needs.
 */
struct MaskCanvas: View {
    let plate: UIImage
    let plateSize: CGSize
    @Binding var drawing: MaskDrawing
    @Binding var brushWidth: CGFloat
    @Binding var erasing: Bool

    @State private var active: MaskStroke?

    var body: some View {
        GeometryReader { geometry in
            let frame = Self.fittedRect(content: plateSize, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: plate)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)

                if let base = drawing.baseMask {
                    // The automatic aperture under the strokes, in the same red
                    // the host's own overlay uses for the garment footprint.
                    Image(uiImage: base)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .blendMode(.screen)
                        .opacity(0.45)
                        .colorMultiply(.red)
                        .allowsHitTesting(false)
                }

                ForEach(Array(drawing.strokes.enumerated()), id: \.offset) { _, stroke in
                    strokePath(stroke, in: frame.size)
                        .stroke(stroke.erase ? Color.black.opacity(0.85) : Color.red.opacity(0.55),
                                style: StrokeStyle(lineWidth: stroke.width * max(frame.width, frame.height),
                                                   lineCap: .round, lineJoin: .round))
                        .frame(width: frame.width, height: frame.height)
                        .allowsHitTesting(false)
                }

                if let active {
                    strokePath(active, in: frame.size)
                        .stroke(active.erase ? Color.black.opacity(0.85) : Color.red.opacity(0.55),
                                style: StrokeStyle(lineWidth: active.width * max(frame.width, frame.height),
                                                   lineCap: .round, lineJoin: .round))
                        .frame(width: frame.width, height: frame.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .offset(x: frame.minX, y: frame.minY)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = Self.normalise(value.location, in: frame)
                        if active == nil {
                            active = MaskStroke(points: [point], width: brushWidth, erase: erasing)
                        } else {
                            // Thin out the sample stream: a finger produces far
                            // more points than a mask edge needs, and every one
                            // of them is a line segment to rasterise later.
                            if let last = active?.points.last,
                               hypot(last.x - point.x, last.y - point.y) < 0.004 {
                                return
                            }
                            active?.points.append(point)
                        }
                    }
                    .onEnded { _ in
                        if let stroke = active { drawing.strokes.append(stroke) }
                        active = nil
                    }
            )
        }
    }

    private func strokePath(_ stroke: MaskStroke, in size: CGSize) -> Path {
        Path { path in
            let points = stroke.points.map {
                CGPoint(x: $0.x * size.width, y: $0.y * size.height)
            }
            guard let first = points.first else { return }
            if points.count == 1 {
                // Mirrors the renderer's dot-for-a-tap behaviour, so the
                // preview does not disagree with what gets uploaded.
                path.addEllipse(in: CGRect(x: first.x - 0.5, y: first.y - 0.5, width: 1, height: 1))
                return
            }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
    }

    /// The plate's `.fit` rectangle inside an available size.
    static func fittedRect(content: CGSize, in available: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else {
            return CGRect(origin: .zero, size: available)
        }
        let scale = min(available.width / content.width, available.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (available.width - size.width) / 2,
                      y: (available.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// A touch in view space, as a fraction of the plate. Clamped: a finger
    /// that slides off the image should end the stroke at the edge rather than
    /// recording coordinates outside the mask.
    static func normalise(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x) / frame.width, 0), 1),
                y: min(max((point.y) / frame.height, 0), 1))
    }
}
