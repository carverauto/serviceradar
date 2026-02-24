#if os(iOS)
import Foundation
import Vision
import CoreML
import simd

public struct APObjectDetectionResult: Identifiable {
    public let id = UUID()
    public let label: String
    public let confidence: Double
    public let boundingBox: CGRect
}

public struct APLabelCandidate: Identifiable {
    public enum Source: String {
        case automatic
        case tapAssist
    }

    public let id = UUID()
    public let suggestedLabel: String
    public let confidence: Double
    public let worldPosition: SIMD3<Float>
    public let source: Source
}

@available(iOS 16.0, *)
public final class APObjectDetector {
    private let detectionQueue = DispatchQueue(label: "com.serviceradar.fieldsurvey.apdetector", qos: .userInitiated)
    private let objectRequest: VNCoreMLRequest?

    private static let apLabelHints = [
        "access point",
        "ap",
        "router",
        "wifi router",
        "wireless router",
        "modem",
        "mesh node"
    ]

    public var isAvailable: Bool {
        objectRequest != nil
    }

    public init() {
        guard
            let modelURL = Bundle.main.url(forResource: "AccessPointDetector", withExtension: "mlmodelc"),
            let model = try? MLModel(contentsOf: modelURL, configuration: MLModelConfiguration()),
            let visionModel = try? VNCoreMLModel(for: model)
        else {
            objectRequest = nil
            return
        }

        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        objectRequest = request
    }

    public func detectAccessPoints(
        in pixelBuffer: CVPixelBuffer,
        completion: @escaping ([APObjectDetectionResult]) -> Void
    ) {
        guard let objectRequest else {
            completion([])
            return
        }

        detectionQueue.async {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            do {
                try handler.perform([objectRequest])
                let observations = objectRequest.results as? [VNRecognizedObjectObservation] ?? []
                let detections: [APObjectDetectionResult] = observations.compactMap { observation in
                    guard let top = observation.labels.first else { return nil }
                    let normalized = top.identifier.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    guard Self.apLabelHints.contains(where: { normalized.contains($0) }) else { return nil }

                    return APObjectDetectionResult(
                        label: top.identifier,
                        confidence: Double(top.confidence),
                        boundingBox: observation.boundingBox
                    )
                }
                .sorted { $0.confidence > $1.confidence }

                DispatchQueue.main.async {
                    completion(detections)
                }
            } catch {
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }
    }
}
#endif
