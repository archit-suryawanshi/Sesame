//
//  FaceMatchCalibration.swift
//  Sesame
//
//  Where the unlock threshold comes from.
//
//  Upstream shipped a fixed 0.66 cosine cutoff. Measured on studio-quality portraits
//  (tools/embedding_bench.swift), genuine probes score 0.61-0.79 and impostors -0.06 to 0.10 — an
//  enormous gap, with 0.66 sitting not in the middle of it but at the very top edge of the genuine
//  range, failing one clean frontal probe in six. A lock-screen webcam is dimmer, lower-resolution
//  and off-angle, which moves genuine scores down but leaves impostors where they are, so a cutoff
//  already at the edge on good photos rejects nearly everything in practice while buying no
//  security the gap wasn't already providing.
//
//  Rather than swap one hardcoded constant for another, this derives the cutoff from the enrollment
//  itself: how close does this person, on this camera, in this room, score against their own gallery?
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

    /// Never calibrate under this however loose the enrollment looks — a bad enrollment should be
    /// recaptured, not accommodated by lowering the gate until anyone passes. Measured impostors
    /// topped out at 0.099, so this leaves roughly 3.5x headroom over the worst observed collision.
    static let floor: Float = 0.36

    /// Enrollment samples are all same-session and same-lighting, so they score optimistically high
    /// next to a real 11pm unlock — measured worst-case genuine was 0.61 on studio portraits alone,
    /// and a tight enrollment therefore asks for a cutoff above that. Letting calibration chase the
    /// number would reproduce upstream's failure at a new value, so it caps out here: still roughly
    /// five times the worst measured impostor collision, with room left for bad light.
    static let ceiling: Float = 0.50

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
