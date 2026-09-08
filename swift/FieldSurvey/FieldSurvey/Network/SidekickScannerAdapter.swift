import Foundation
import CoreLocation
import simd

public struct SidekickScannerAdapterContext {
    public let scannerDeviceID: String
    public let latestDevicePose: SIMD3<Float>?
    public let location: CLLocationCoordinate2D?

    public init(
        scannerDeviceID: String,
        latestDevicePose: SIMD3<Float>?,
        location: CLLocationCoordinate2D?
    ) {
        self.scannerDeviceID = scannerDeviceID
        self.latestDevicePose = latestDevicePose
        self.location = location
    }
}

public final class SidekickScannerAdapter: @unchecked Sendable {
    public init() {}

    public func events(
        from observations: [SidekickObservation],
        context: SidekickScannerAdapterContext
    ) -> [SurveySampleIngestEvent] {
        guard !observations.isEmpty else { return [] }

        let measurementPosition = context.latestDevicePose
        let samplePosition = measurementPosition ?? SIMD3<Float>(0, 0, 0)
        let rfVector = buildRFVector(from: observations)

        return observations.map { observation in
            let rssi = Double(observation.rssiDBM ?? Int(SurveySample.missingSignalValue))
            let ssid = displaySSID(from: observation)
            let confidence = min(max(observation.parserConfidence, 0.0), 1.0)
            let timestamp = observation.capturedAtUnixNanos > 0
                ? TimeInterval(observation.capturedAtUnixNanos) / 1_000_000_000
                : Date().timeIntervalSince1970

            let sample = SurveySample(
                id: UUID(),
                timestamp: timestamp,
                scannerDeviceId: context.scannerDeviceID,
                bssid: observation.bssid,
                ssid: ssid,
                rssi: rssi,
                frequency: observation.frequencyMHz,
                securityType: "Sidekick \(observation.frameType)",
                isSecure: false,
                rfVector: rfVector,
                position: samplePosition,
                latitude: context.location?.latitude ?? 0.0,
                longitude: context.location?.longitude ?? 0.0,
                uncertainty: Float(1.0 - confidence)
            )

            let localizationObservation = context.latestDevicePose.map { pose in
                APPositionObservation(
                    timestamp: timestamp,
                    bssid: observation.bssid,
                    frequencyMHz: observation.frequencyMHz,
                    rssi: rssi,
                    scannerPosition: pose
                )
            }

            return SurveySampleIngestEvent(
                source: .sidekick,
                sample: sample,
                heatmapPosition: measurementPosition,
                localizationObservation: localizationObservation
            )
        }
    }

    private func buildRFVector(from observations: [SidekickObservation]) -> [Double] {
        observations
            .compactMap { observation in
                observation.rssiDBM.map(Double.init)
            }
            .sorted(by: >)
    }

    private func displaySSID(from observation: SidekickObservation) -> String {
        if observation.hiddenSSID {
            return "Hidden SSID"
        }

        let trimmedSSID = observation.ssid?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedSSID.isEmpty ? observation.bssid : trimmedSSID
    }
}
