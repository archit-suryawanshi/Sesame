//
//  FaceMatchCalibration.swift
//  glance
//
//  Where the unlock threshold comes from.
//
//  Upstream shipped a fixed 0.66 cosine cutoff against ArcFace w600k_mbf, whose own documented
//  operating range is roughly 0.28-0.40 (see FaceEmbedding.cosineSimilarity). Nothing a real face
//  produced could clear it, so unlocks never fired. Rather than swap one hardcoded constant for
//  another, this derives the cutoff from the enrollment itself: how close does this person, on this
//  camera, in this room, actually score against their own gallery?
//

import Foundation

/// The genuine-match statistics measured across one identity's own enrolled samples, plus the
/// threshold they imply. Surfaced in Settings so the number is inspectable rather than magic.
struct FaceMatchCalibration: Codable, Equatable {
    /// Worst leave-one-out score across the enrollment — the hardest pose to recognize.
    let worstGenuineScore: Float
    /// Median leave-one-out score. Only shown, never used in the maths; a large gap between this
    /// and `worstGenuineScore` means one pose is an outlier worth re-capturing.
    let medianGenuineScore: Float
    let sampleCount: Int
    let measuredAt: Date
    /// What `recommendedThreshold` produced from the above, after clamping.
    let threshold: Float

    /// Below this, the impostor tail of a 512-d ArcFace embedding starts to matter. Never calibrate
    /// under it however loose the enrollment looks — a bad enrollment should be recaptured, not
    /// accommodated by lowering the gate until anyone passes.
    static let floor: Float = 0.36

    /// Above this there is nothing left to gain: enrollment samples are all same-session and
    /// same-lighting, so they score optimistically high next to a real 11pm unlock. Letting the
    /// calibration chase that number would fail every unlock that isn't in enrollment conditions.
    static let ceiling: Float = 0.55

    /// Headroom under the worst observed genuine score, for conditions enrollment never saw.
    private static let margin: Float = 0.05

    /// Leave-one-out over the gallery: score every sample the way an unlock would — against the
    /// *other* samples — and take the worst case. Returns nil below four samples, where the
    /// statistic is too thin to mean anything and the fixed default is the honest answer.
    static func measure(samples: [FaceSample], now: Date = Date()) -> FaceMatchCalibration? {
        guard samples.count >= 4 else { return nil }

        var scores: [Float] = []
        scores.reserveCapacity(samples.count)
        for (index, sample) in samples.enumerated() {
            let others = samples.enumerated().filter { $0.offset != index }.map(\.element.embedding)
            let similarities = others.map { FaceEmbedding.cosineSimilarity(sample.embedding, $0) }
            guard let score = FaceEmbedding.topKMean(similarities) else { continue }
            scores.append(score)
        }
        guard let worst = scores.min(), scores.count >= 4 else { return nil }

        let sorted = scores.sorted()
        let median = sorted[sorted.count / 2]

        return FaceMatchCalibration(
            worstGenuineScore: worst,
            medianGenuineScore: median,
            sampleCount: samples.count,
            measuredAt: now,
            threshold: min(max(worst - margin, floor), ceiling)
        )
    }
}
