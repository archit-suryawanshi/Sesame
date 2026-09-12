//
//  FaceRecognitionPipeline.swift
//  Sesame
//
//  Only place that should construct a FaceEmbedder — keeps all consumers in sync.
//

import Foundation
import CoreGraphics
import Observation

nonisolated struct FaceRecognitionResult {
    let embedding: [Float]
    /// What was actually fed to the embedder, for debug UIs to inspect.
    let alignedImage: CGImage
    let alignmentTier: AlignmentTier
    let quality: Float?
    let face: DetectedFace
}

nonisolated enum FaceRecognitionPipelineError: LocalizedError {
    case noFaceDetected
    case alignmentFailed

    var errorDescription: String? {
        switch self {
        case .noFaceDetected: return "No face detected in frame."
        case .alignmentFailed: return "Could not align the detected face."
        }
    }
}

/// `@Observable` so the debug UI can surface which embedder is active.
@Observable
@MainActor
final class FaceRecognitionPipeline {
    nonisolated let embedder: FaceEmbedder

    /// Set when ArcFace failed to load (see tools/convert_arcface.py) and the weaker Vision feature-print embedder is in use instead.
    private(set) var usingFallbackEmbedder: Bool
    private(set) var fallbackReason: String?

    init() {
        do {
            embedder = try ArcFaceEmbedder()
            usingFallbackEmbedder = false
            fallbackReason = nil
        } catch {
            embedder = VisionFeaturePrintEmbedder()
            usingFallbackEmbedder = true
            fallbackReason = error.localizedDescription
        }
    }

    /// `nonisolated` so callers can run detect/align/embed from a background task instead of blocking the main actor.
    /// - Parameter previousBoundingBox: previous frame's selected box, if any — lets a continuous scanner keep selection "stuck" to the same person instead of re-picking every frame.
    nonisolated func recognize(in frame: CGImage, preferNear previousBoundingBox: CGRect? = nil) throws -> FaceRecognitionResult {
        let faces = try FaceDetector.detectFaces(in: frame)
        guard let face = Self.selectDominantFace(in: faces, preferNear: previousBoundingBox) else {
            throw FaceRecognitionPipelineError.noFaceDetected
        }
        return try recognize(face, in: frame)
    }

    /// Aligns and embeds an already-chosen face; enrollment uses this to bypass the prominence filter so a too-small face reads as "move closer" rather than "nobody there".
    nonisolated func recognize(_ face: DetectedFace, in frame: CGImage) throws -> FaceRecognitionResult {
        let inputImage: CGImage
        let tier: AlignmentTier
        if embedder.requiresAlignment {
            guard let aligned = FaceAligner.align(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = aligned.image
            tier = aligned.tier
        } else {
            guard let cropped = FaceDetector.crop(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = cropped
            tier = .paddedCrop
        }

        let embedding = try embedder.embedding(for: inputImage)
        return FaceRecognitionResult(embedding: embedding, alignedImage: inputImage, alignmentTier: tier, quality: face.quality, face: face)
    }

    /// Largest face by area with no prominence cutoff — unlike `selectDominantFace`, so enrollment can tell "too far" apart from "no face".
    nonisolated static func largestFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    /// Below this fraction of frame width, a face is treated as a bystander, not a candidate — shared with onboarding's "move closer" prompt. `nonisolated(unsafe)` because it's read from a background-task static func that can't touch SesameSettings' MainActor-isolated storage.
    nonisolated(unsafe) static var minimumProminentFaceWidth: Float = 0.18

    /// Max normalized-coordinate drift between frames still counted as "the same person".
    nonisolated private static let continuityDistanceTolerance: CGFloat = 0.3

    /// Picks the person actually at the camera, not a bystander: filters out faces below `minimumProminentFaceWidth`, then prefers continuity with `previousBoundingBox` over raw largest-by-area so two similarly-sized faces can't flip-flop the selection frame to frame and starve the liveness/wrong-face streaks of agreement.
    nonisolated static func selectDominantFace(in faces: [DetectedFace], preferNear previousBoundingBox: CGRect? = nil) -> DetectedFace? {
        let candidates = faces.filter { $0.normalizedBoundingBox.width >= CGFloat(minimumProminentFaceWidth) }
        guard !candidates.isEmpty else { return nil }

        if let previous = previousBoundingBox {
            let previousCenter = CGPoint(x: previous.midX, y: previous.midY)
            if let nearest = candidates.min(by: { distance(from: $0, to: previousCenter) < distance(from: $1, to: previousCenter) }),
               distance(from: nearest, to: previousCenter) < continuityDistanceTolerance {
                return nearest
            }
        }

        return candidates.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    nonisolated private static func distance(from face: DetectedFace, to point: CGPoint) -> CGFloat {
        let center = CGPoint(x: face.normalizedBoundingBox.midX, y: face.normalizedBoundingBox.midY)
        return hypot(center.x - point.x, center.y - point.y)
    }
}

nonisolated struct ScoredIdentity {
    let identity: FaceIdentity
    /// Similarity against the identity's averaged template.
    let centroidSimilarity: Float
    /// Similarity against the single closest individual sample — catches
    /// cases where averaging blurred together poses that shouldn't be
    /// blended.
    let maxSampleSimilarity: Float
    /// Mean of the three closest samples. This is what an unlock is decided on —
    /// see `FaceEmbedding.topKMean` for why it beats either of the two above.
    let matchScore: Float

    /// The cutoff this identity is actually judged against: its own measured calibration where one
    /// exists, otherwise the global fallback, in both cases nudged by the user's strictness pick.
    nonisolated func threshold(fallback: Float, offset: Float) -> Float {
        let base = identity.calibration?.threshold ?? fallback
        return min(max(base + offset, FaceMatchCalibration.floor), 0.65)
    }
}

extension FaceRecognitionPipeline {
    /// Sorted by centroid similarity descending; includes stale identities (different embedder) since `bestMatch` is what excludes them from actually matching.
    nonisolated func score(_ embedding: [Float], against identities: [FaceIdentity]) -> [ScoredIdentity] {
        identities.compactMap { identity in
            guard let template = identity.template, !identity.samples.isEmpty else { return nil }
            let centroidSim = FaceEmbedding.cosineSimilarity(embedding, template)
            let similarities = identity.samples.map { FaceEmbedding.cosineSimilarity(embedding, $0.embedding) }
            let maxSim = similarities.max() ?? centroidSim
            let matchScore = FaceEmbedding.topKMean(similarities) ?? centroidSim
            return ScoredIdentity(
                identity: identity,
                centroidSimilarity: centroidSim,
                maxSampleSimilarity: maxSim,
                matchScore: matchScore
            )
        }.sorted { $0.matchScore > $1.matchScore }
    }

    /// How far the centroid may sit under the match threshold and still pass.
    ///
    /// Upstream required the centroid and the best sample to *each* clear the threshold, so two
    /// separately-noisy measurements both had to land — each one an independent chance to fail an
    /// unlock that should have succeeded. The centroid stays, but as a *sanity* check rather than an
    /// equal gate: measured impostors sit around 0.01 and never above 0.10, so slackening it by this
    /// much costs nothing in rejection while still catching a probe that hugs a couple of outlier
    /// samples without resembling the person overall.
    nonisolated static let centroidSlack: Float = 0.12

    /// Shared by Face Lab and FaceUnlockCoordinator so tuning stays consistent. No runner-up margin check: the same person can be enrolled multiple times under different appearances, so two of their own profiles legitimately score close together — a margin check can't tell that apart from two different people colliding.
    /// `override` replaces the per-identity calibration outright — for Face Lab's threshold slider,
    /// which has to be able to sweep the cutoff to be worth anything. The real unlock path never
    /// passes it, so the debug tool sharing this function can't quietly change the live gate.
    nonisolated func bestMatch(
        in scored: [ScoredIdentity],
        fallbackThreshold: Float,
        offset: Float = 0,
        override: Float? = nil
    ) -> ScoredIdentity? {
        guard let first = scored.first, !first.identity.isStale(comparedTo: embedder) else { return nil }
        let threshold = override ?? first.threshold(fallback: fallbackThreshold, offset: offset)
        guard first.matchScore >= threshold else { return nil }
        guard first.centroidSimilarity >= threshold - Self.centroidSlack else { return nil }
        return first
    }
}
