import Foundation
import simd

public enum SurveySampleSource: String, Sendable {
    case nativeWiFi
    case hotspotHelper
    case subnet
    case sidekick
    case manual
}

public struct SurveySampleIngestEvent {
    public let source: SurveySampleSource
    public let sample: SurveySample
    public let heatmapPosition: SIMD3<Float>?
    public let localizationObservation: APPositionObservation?

    public init(
        source: SurveySampleSource,
        sample: SurveySample,
        heatmapPosition: SIMD3<Float>? = nil,
        localizationObservation: APPositionObservation? = nil
    ) {
        self.source = source
        self.sample = sample
        self.heatmapPosition = heatmapPosition
        self.localizationObservation = localizationObservation
    }
}
