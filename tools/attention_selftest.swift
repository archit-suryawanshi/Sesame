//
//  attention_selftest.swift
//  Sesame (tools)
//
//  Exercises AttentionDetector's geometry on synthetic eyes, since VNFaceLandmarks2D cannot be
//  constructed by hand. Checks that a centred gaze passes, a sideways glance is rejected, and that
//  a rolled head still reads as centred — the claim the face-axis projection exists to support.
//
//  Build and run from the repo root:
//    swiftc -O -o /tmp/attention_selftest \
//      tools/attention_selftest.swift Sesame/AttentionDetector.swift \
//      Sesame/FaceDetector.swift Sesame/Liveness/LandmarkGeometry.swift \
//      Sesame/Liveness/LivenessCues.swift Sesame/Liveness/LivenessScoring.swift \
//      Sesame/Liveness/GeometryLiveness.swift Sesame/Liveness/GlareCue.swift
//    /tmp/attention_selftest
//

import Foundation
import CoreGraphics

@main
struct AttentionSelfTest {
    /// An eye as an axis-aligned ellipse of points, then rotated by `roll` about the face centre.
    static func eye(center: CGPoint, halfWidth: CGFloat, halfHeight: CGFloat, roll: CGFloat, about pivot: CGPoint) -> [CGPoint] {
        let points = (0..<12).map { i -> CGPoint in
            let t = CGFloat(i) / 12 * 2 * .pi
            return CGPoint(x: center.x + halfWidth * cos(t), y: center.y + halfHeight * sin(t))
        }
        return points.map { rotate($0, by: roll, about: pivot) }
    }

    static func rotate(_ point: CGPoint, by radians: CGFloat, about pivot: CGPoint) -> CGPoint {
        let dx = point.x - pivot.x, dy = point.y - pivot.y
        return CGPoint(
            x: pivot.x + dx * cos(radians) - dy * sin(radians),
            y: pivot.y + dx * sin(radians) + dy * cos(radians)
        )
    }

    /// `gaze` shifts both pupils along the face's horizontal axis, as a fraction of eye half-width.
    static func makeCase(roll: CGFloat, gaze: CGFloat, verticalGaze: CGFloat = 0)
    -> (CGPoint, CGPoint, [CGPoint], [CGPoint]) {
        let pivot = CGPoint(x: 300, y: 300)
        let halfWidth: CGFloat = 30, halfHeight: CGFloat = 14
        let leftCenter = CGPoint(x: 240, y: 300)
        let rightCenter = CGPoint(x: 360, y: 300)

        let leftEye = eye(center: leftCenter, halfWidth: halfWidth, halfHeight: halfHeight, roll: roll, about: pivot)
        let rightEye = eye(center: rightCenter, halfWidth: halfWidth, halfHeight: halfHeight, roll: roll, about: pivot)

        let offset = CGPoint(x: gaze * halfWidth, y: verticalGaze * halfHeight)
        let leftPupil = rotate(CGPoint(x: leftCenter.x + offset.x, y: leftCenter.y + offset.y), by: roll, about: pivot)
        let rightPupil = rotate(CGPoint(x: rightCenter.x + offset.x, y: rightCenter.y + offset.y), by: roll, about: pivot)
        return (leftPupil, rightPupil, leftEye, rightEye)
    }

    static func check(
        _ label: String, roll: CGFloat = 0, gaze: CGFloat = 0, verticalGaze: CGFloat = 0,
        yaw: Float? = 0, pitch: Float? = 0, expectAttentive: Bool
    ) {
        let (lp, rp, le, re) = makeCase(roll: roll, gaze: gaze, verticalGaze: verticalGaze)
        guard let reading = AttentionDetector.evaluate(
            leftPupil: lp, rightPupil: rp, leftEye: le, rightEye: re, yaw: yaw, pitch: pitch
        ) else {
            fatalError("FAIL: \(label) produced no reading at all.")
        }
        guard reading.isAttentive == expectAttentive else {
            fatalError(String(
                format: "FAIL: %@ expected attentive=%@ got %@ (h=%.3f v=%.3f, %@)",
                label, expectAttentive ? "true" : "false", reading.isAttentive ? "true" : "false",
                reading.horizontalOffset, reading.verticalOffset, reading.reason ?? "no reason"
            ))
        }
        print(String(format: "PASS: %-46@ h=%+.3f v=%+.3f%@", label as NSString,
                     reading.horizontalOffset, reading.verticalOffset,
                     reading.reason.map { "  (\($0))" } ?? ""))
    }

    static func main() {
        check("looking straight at the screen", expectAttentive: true)
        check("glancing well to the side", gaze: 0.9, expectAttentive: false)
        check("glancing the other way", gaze: -0.9, expectAttentive: false)
        check("a small drift still counts as looking", gaze: 0.2, expectAttentive: true)
        check("looking sharply down past the screen", verticalGaze: 1.1, expectAttentive: false)
        // The camera is above the screen, so this is what looking *at* the screen looks like.
        check("looking down at the middle of the screen", verticalGaze: 0.5, expectAttentive: true)
        check("looking up, away from the screen", verticalGaze: -0.6, expectAttentive: false)

        // The reason the offsets are projected onto the face's own axes.
        for degrees in stride(from: -25.0, through: 25.0, by: 12.5) {
            let roll = CGFloat(degrees) * .pi / 180
            check(String(format: "head rolled %+.0f degrees, eyes centred", degrees),
                  roll: roll, expectAttentive: true)
            check(String(format: "head rolled %+.0f degrees, eyes to the side", degrees),
                  roll: roll, gaze: 0.9, expectAttentive: false)
        }

        // Head pose overrides the eyes: a face turned away is not looking at the Mac.
        check("head turned away, eyes centred in their sockets", yaw: 40 * .pi / 180, expectAttentive: false)
        check("head tilted away, eyes centred in their sockets", pitch: 40 * .pi / 180, expectAttentive: false)
        check("head pose unavailable, eyes centred", yaw: nil, pitch: nil, expectAttentive: true)

        print("\nAll attention self-tests passed.")
    }
}
