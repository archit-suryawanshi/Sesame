//
//  AttentionDetector.swift
//  Sesame
//
//  "Require attention", the way Face ID means it: your face being pointed at the Mac is not enough,
//  your eyes have to be on it too. Look off to the side while your face stays square to the camera
//  and this refuses, which is the whole point — it is what stops a sleeping, distracted or unwilling
//  person's face being used to unlock the machine in front of them.
//
//  macOS has no gaze API. ARKit's `lookAtPoint` needs a TrueDepth camera, which a Mac does not have.
//  So gaze is estimated from where each pupil sits inside its own eye opening, measured along the
//  face's own axes rather than the image's, so it survives a tilted head.
//
//  Being an estimate, it is a coarse one: it reliably separates "looking at the screen" from
//  "looking well off to the side", and it does not pretend to know precisely where on the screen you
//  are looking.
//

import Foundation
import CoreGraphics
import Vision

struct AttentionReading {
    /// How far the gaze sits from centred, as a fraction of eye width. 0 is dead centre.
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    /// Head rotation towards the screen, in degrees.
    let yawDegrees: Float?
    let pitchDegrees: Float?
    let isAttentive: Bool
    /// Why it was not attentive, for the log and Face Lab.
    let reason: String?
}

nonisolated enum AttentionDetector {
    /// Gaze may sit this far off centre, as a fraction of the eye's own width, and still count as
    /// looking at the screen. A Mac screen subtends a wide angle at arm's length, so this is
    /// deliberately not tight: the target is to reject a clear glance away, not to demand a stare.
    static let horizontalTolerance: CGFloat = 0.20
    /// Vertical is asymmetric, and deliberately so. The camera sits above the screen, so looking at
    /// the screen *always* means looking somewhat down: at a typical laptop distance the middle of
    /// the display is 10-15 degrees below the lens, which moves the iris a good quarter of the eye
    /// opening. Treating that as a glance away would reject everyone, every time. Looking up, by
    /// contrast, is never where the screen is.
    ///
    /// Eyelids also clip the top and bottom of the iris, so this is the noisier of the two
    /// measurements regardless of direction.
    static let downwardTolerance: CGFloat = 0.45
    static let upwardTolerance: CGFloat = 0.22

    /// Head rotation beyond this is not looking at the Mac whatever the eyes are doing.
    static let maximumYawDegrees: Float = 22
    static let maximumPitchDegrees: Float = 22

    /// Consecutive attentive frames required. One frame is a blink away from meaningless.
    static let requiredFrames = 3

    /// `nil` when attention cannot be judged at all — no pupils resolved, typically low light or a
    /// heavy glasses reflection. Deliberately distinct from "not attentive": the caller reports it
    /// differently, because "I could not see your eyes" and "you were looking away" need different
    /// things from the user.
    static func read(_ face: DetectedFace) -> AttentionReading? {
        guard let landmarks = face.landmarks,
              let leftEyeRegion = landmarks.leftEye,
              let rightEyeRegion = landmarks.rightEye,
              let leftPupilRegion = landmarks.leftPupil,
              let rightPupilRegion = landmarks.rightPupil
        else { return nil }

        let size = face.imageSize
        guard let leftPupil = LandmarkGeometry.centroid(of: leftPupilRegion, imageSize: size),
              let rightPupil = LandmarkGeometry.centroid(of: rightPupilRegion, imageSize: size)
        else { return nil }

        let leftEye = LandmarkGeometry.imagePoints(of: leftEyeRegion, imageSize: size)
        let rightEye = LandmarkGeometry.imagePoints(of: rightEyeRegion, imageSize: size)

        return evaluate(
            leftPupil: leftPupil, rightPupil: rightPupil,
            leftEye: leftEye, rightEye: rightEye,
            yaw: face.yaw, pitch: face.pitch
        )
    }

    /// The geometry, separated from Vision so it can be tested. `VNFaceLandmarks2D` has no public
    /// initializer, so anything that takes one is untestable by construction.
    static func evaluate(
        leftPupil: CGPoint,
        rightPupil: CGPoint,
        leftEye: [CGPoint],
        rightEye: [CGPoint],
        yaw: Float?,
        pitch: Float?
    ) -> AttentionReading? {
        guard leftEye.count >= 4, rightEye.count >= 4 else { return nil }

        // The face's own horizontal axis, so a tilted head does not read as a sideways glance.
        guard let axis = faceAxis(leftPupil: leftPupil, rightPupil: rightPupil) else { return nil }

        guard let left = offsets(pupil: leftPupil, eye: leftEye, axis: axis),
              let right = offsets(pupil: rightPupil, eye: rightEye, axis: axis)
        else { return nil }

        // Averaged, not worst-of: one eye is often partly occluded by the nose bridge at an angle,
        // and its estimate degrades first.
        let horizontal = (left.horizontal + right.horizontal) / 2
        let vertical = (left.vertical + right.vertical) / 2

        let yawDegrees = yaw.map { $0 * 180 / .pi }
        let pitchDegrees = pitch.map { $0 * 180 / .pi }

        var reason: String?
        if let yawDegrees, abs(yawDegrees) > maximumYawDegrees {
            reason = String(format: "head turned %.0f degrees away", abs(yawDegrees))
        } else if let pitchDegrees, abs(pitchDegrees) > maximumPitchDegrees {
            reason = String(format: "head tilted %.0f degrees away", abs(pitchDegrees))
        } else if abs(horizontal) > horizontalTolerance {
            reason = String(format: "eyes looking %@ (%.2f)", horizontal > 0 ? "right" : "left", abs(horizontal))
        } else if vertical > downwardTolerance {
            reason = String(format: "eyes looking down past the screen (%.2f)", vertical)
        } else if vertical < -upwardTolerance {
            reason = String(format: "eyes looking up past the screen (%.2f)", -vertical)
        }

        return AttentionReading(
            horizontalOffset: horizontal,
            verticalOffset: vertical,
            yawDegrees: yawDegrees,
            pitchDegrees: pitchDegrees,
            isAttentive: reason == nil,
            reason: reason
        )
    }

    /// Unit vector from the left pupil to the right one — the face's horizontal, whatever the roll.
    private static func faceAxis(leftPupil: CGPoint, rightPupil: CGPoint) -> CGVector? {
        let dx = rightPupil.x - leftPupil.x
        let dy = rightPupil.y - leftPupil.y
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        return CGVector(dx: dx / length, dy: dy / length)
    }

    /// Where the pupil sits inside its eye opening, as a signed fraction of that opening, measured
    /// along the face's axes. 0 is centred; +horizontal is towards the subject's right.
    private static func offsets(
        pupil: CGPoint, eye: [CGPoint], axis: CGVector
    ) -> (horizontal: CGFloat, vertical: CGFloat)? {
        let perpendicular = CGVector(dx: -axis.dy, dy: axis.dx)

        let along = eye.map { $0.x * axis.dx + $0.y * axis.dy }
        let across = eye.map { $0.x * perpendicular.dx + $0.y * perpendicular.dy }
        guard let minAlong = along.min(), let maxAlong = along.max(),
              let minAcross = across.min(), let maxAcross = across.max()
        else { return nil }

        let width = maxAlong - minAlong
        let height = maxAcross - minAcross
        // A near-zero opening is a closed eye or a bad landmark set, not a centred gaze.
        guard width > 2, height > 1 else { return nil }

        let pupilAlong = pupil.x * axis.dx + pupil.y * axis.dy
        let pupilAcross = pupil.x * perpendicular.dx + pupil.y * perpendicular.dy

        return (
            horizontal: (pupilAlong - minAlong) / width - 0.5,
            vertical: (pupilAcross - minAcross) / height - 0.5
        )
    }
}
