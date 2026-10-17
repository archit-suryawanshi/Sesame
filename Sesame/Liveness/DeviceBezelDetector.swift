//
//  DeviceBezelDetector.swift
//  Sesame
//
//  Looks for a device bezel (phone/tablet) around the face via
//  VNDetectRectanglesRequest; only ever produces positive evidence of
//  spoofing, never positive evidence of liveness.
//

import Vision
import CoreGraphics

struct DeviceBezelObservation {
    /// Largest device-plausible rectangle found this frame, same pixel space as `DetectedFace.boundingBox`.
    let rectangle: CGRect?
    /// Fraction of the face's bounding box area that falls inside `rectangle`.
    let faceOverlapFraction: CGFloat?

    nonisolated static let none = DeviceBezelObservation(rectangle: nil, faceOverlapFraction: nil)
}

nonisolated enum DeviceBezelDetector {
    /// How much of the face must sit inside the rectangle before it counts as framed rather than
    /// merely overlapped. A phone held up to spoof a face puts essentially all of it inside.
    static let minimumFaceContainment: CGFloat = 0.85
    /// And the rectangle has to be bigger than the face it is supposedly displaying.
    static let minimumAreaRatio: CGFloat = 1.5

    /// First-pass estimates, not validated against real footage — tune here if false positives/negatives show up.
    private static func makeRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        // Fraction of image area, not width/height.
        request.minimumSize = 0.15
        request.maximumObservations = 3
        // Covers phone-in-portrait (0.35) through near-square tablet crop (1.0).
        request.minimumAspectRatio = 0.35
        request.maximumAspectRatio = 1.0
        // Generous so a phone held at a slight angle still registers.
        request.quadratureTolerance = 30

        return request
    }

    /// Synchronous and CPU-bound — call from a background task, same as `FaceDetector.detectFaces`.
    static func detect(in image: CGImage, faceBoundingBox: CGRect) -> DeviceBezelObservation {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results, !results.isEmpty
        else { return .none }

        let imageSize = CGSize(width: image.width, height: image.height)
        let candidates = results.map { FaceDetector.convertToImageSpace($0.boundingBox, imageSize: imageSize) }
        // Largest candidate is assumed to be the device itself, not a smaller qualifying detail.
        guard let largest = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return .none
        }

        let faceArea = faceBoundingBox.width * faceBoundingBox.height
        guard faceArea > 0 else { return DeviceBezelObservation(rectangle: largest, faceOverlapFraction: nil) }
        let intersection = largest.intersection(faceBoundingBox)
        let overlap = (intersection.width * intersection.height) / faceArea

        // The cue is "a device is being held up with a face on it", and that has a specific shape:
        // the rectangle *contains* the face and is bigger than it. Any old rectangle that clips a
        // corner of the face does not — and a lock screen has plenty of those behind the user, a
        // door frame, a monitor, a picture. Reporting bare overlap denied a real face in testing on
        // the strength of furniture.
        guard overlap >= minimumFaceContainment,
              largest.width * largest.height >= faceArea * minimumAreaRatio
        else { return DeviceBezelObservation(rectangle: largest, faceOverlapFraction: nil) }

        return DeviceBezelObservation(rectangle: largest, faceOverlapFraction: overlap)
    }
}
