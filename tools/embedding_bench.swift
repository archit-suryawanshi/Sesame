//
//  embedding_bench.swift
//
//  Runs the app's real detect -> align -> embed path over a folder of face images and prints the
//  genuine/impostor similarity split, so the thresholds in FaceMatchCalibration are chosen from
//  measurements rather than from what a threshold "should" be.
//
//  Build (from the repo root):
//    swiftc -O -o /tmp/embedding_bench \
//      tools/embedding_bench.swift \
//      Sesame/FaceDetector.swift Sesame/FaceAligner.swift Sesame/FaceEmbedder.swift \
//      Sesame/ArcFaceEmbedder.swift Sesame/Liveness/LandmarkGeometry.swift \
//      Sesame/Liveness/LivenessCues.swift Sesame/Liveness/LivenessScoring.swift
//
//  Run:
//    /tmp/embedding_bench <ArcFace.mlmodelc> <image-dir> <pairs-file>
//
//  pairs-file is one "imgA imgB same|diff" per line.
//

import Foundation
import CoreGraphics
import ImageIO

func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    // kCGImageSourceCreateThumbnailFromImageAlways applies the EXIF orientation, which several of
    // these test photos carry; without it a sideways face simply fails to detect.
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 1600,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// Mirrors FaceRecognitionPipeline's helper without dragging the @MainActor class in.
enum FaceRecognitionPipelineShim {
    static func largestFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }
}


@main
struct EmbeddingBench {
    static func describe(_ label: String, _ values: [Float]) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Float(values.count)
        print(String(format: "%@: n=%d  min=%.4f  mean=%.4f  max=%.4f", label, values.count, sorted.first!, mean, sorted.last!))
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 || arguments.count == 5 else {
            FileHandle.standardError.write("usage: embedding_bench <ArcFace.mlmodelc> <image-dir> <pairs-file> [embeddings-out.json]\n".data(using: .utf8)!)
            exit(2)
        }

        let embedder = try ArcFaceEmbedder(explicitModelURL: URL(fileURLWithPath: arguments[1]))
        let imageDirectory = URL(fileURLWithPath: arguments[2])

        var embeddings: [String: [Float]] = [:]
        var alignmentTiers: [String: String] = [:]

        func embedding(for name: String) -> [Float]? {
            if let cached = embeddings[name] { return cached }
            guard let image = loadImage(imageDirectory.appendingPathComponent(name)) else {
                print("  ! could not read \(name)")
                return nil
            }
            guard let faces = try? FaceDetector.detectFaces(in: image),
                  let face = FaceRecognitionPipelineShim.largestFace(in: faces) else {
                print("  ! no face detected in \(name)")
                return nil
            }
            guard let aligned = FaceAligner.align(face, from: image) else {
                print("  ! could not align \(name)")
                return nil
            }
            guard let raw = try? embedder.embedding(for: aligned.image) else {
                print("  ! could not embed \(name)")
                return nil
            }
            alignmentTiers[name] = aligned.tier.rawValue
            embeddings[name] = raw
            return raw
        }

        let pairLines = (try String(contentsOf: URL(fileURLWithPath: arguments[3]), encoding: .utf8))
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var genuine: [Float] = []
        var impostor: [Float] = []

        print("pair                              expected   cosine")
        print("----------------------------------------------------")
        for line in pairLines {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count == 3 else { continue }
            let (a, b, label) = (fields[0], fields[1], fields[2])
            guard let ea = embedding(for: a), let eb = embedding(for: b) else { continue }
            let similarity = FaceEmbedding.cosineSimilarity(ea, eb)
            if label == "same" { genuine.append(similarity) } else { impostor.append(similarity) }
            print(String(format: "%-33@ %-10@ %.4f", "\(a) vs \(b)" as NSString, label as NSString, similarity))
        }

        print("")
        describe("genuine ", genuine)
        describe("impostor", impostor)
        if let worstGenuine = genuine.min(), let bestImpostor = impostor.max() {
            print(String(format: "\nseparation: %.4f  (any threshold in %.3f...%.3f is error-free here)",
                         worstGenuine - bestImpostor, bestImpostor, worstGenuine))
        }
        // Optional 4th argument: dump every embedding as JSON so gallery-level behaviour
        // (centroid vs top-k vs max) can be analysed without re-running inference.
        if arguments.count >= 5 {
            let payload = try JSONSerialization.data(withJSONObject: embeddings.mapValues { $0.map(Double.init) })
            try payload.write(to: URL(fileURLWithPath: arguments[4]))
            print("\nwrote embeddings to \(arguments[4])")
        }

        print("\nalignment tiers:")
        for (name, tier) in alignmentTiers.sorted(by: { $0.key < $1.key }) { print("  \(name): \(tier)") }

    }
}
