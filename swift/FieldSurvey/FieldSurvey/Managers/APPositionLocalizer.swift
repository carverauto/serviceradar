#if os(iOS)
import Foundation
import simd

public struct WiFiRoamEvent: Identifiable {
    public let id = UUID()
    public let timestamp: TimeInterval
    public let ssid: String
    public let fromBSSID: String
    public let toBSSID: String
    public let position: SIMD3<Float>
    public let latitude: Double
    public let longitude: Double
}

public struct APResolvedLocation: Equatable {
    public let position: SIMD3<Float>
    public let confidence: Float
    public let observationCount: Int
    public let residualErrorMeters: Float
}

public struct APPositionObservation: Equatable {
    public let timestamp: TimeInterval
    public let bssid: String
    public let frequencyMHz: Int
    public let rssi: Double
    public let scannerPosition: SIMD3<Float>
}

/// Computes an approximate AP position from multiple RSSI+pose observations.
/// This is not monitor-mode RF trilateration; it is an iOS-safe geometric estimate.
public final class APPositionLocalizer {
    private var observationsByBSSID: [String: [APPositionObservation]] = [:]
    private let maxObservationsPerBSSID = 120

    public init() {}

    public func addObservation(_ observation: APPositionObservation) -> APResolvedLocation? {
        var observations = observationsByBSSID[observation.bssid, default: []]
        observations.append(observation)
        if observations.count > maxObservationsPerBSSID {
            observations.removeFirst(observations.count - maxObservationsPerBSSID)
        }
        observationsByBSSID[observation.bssid] = observations

        return solve(observations)
    }

    public func clear() {
        observationsByBSSID.removeAll()
    }

    private func solve(_ observations: [APPositionObservation]) -> APResolvedLocation? {
        guard observations.count >= 6 else { return nil }

        // Need enough walk spread; otherwise solutions collapse to unstable points.
        let positions = observations.map(\.scannerPosition)
        let minX = positions.map(\.x).min() ?? 0
        let maxX = positions.map(\.x).max() ?? 0
        let minY = positions.map(\.y).min() ?? 0
        let maxY = positions.map(\.y).max() ?? 0
        let minZ = positions.map(\.z).min() ?? 0
        let maxZ = positions.map(\.z).max() ?? 0
        let spread = max(maxX - minX, max(maxY - minY, maxZ - minZ))
        guard spread >= 1.2 else { return nil }

        let weighted = observations.map { obs -> (position: SIMD3<Float>, distance: Float, weight: Float) in
            let distance = estimatedDistanceMeters(rssi: obs.rssi, frequencyMHz: obs.frequencyMHz)
            let signalWeight = Float(max(0.1, min(1.0, (obs.rssi + 100.0) / 55.0)))
            return (obs.scannerPosition, distance, signalWeight)
        }

        var estimate = SIMD3<Float>(0, 0, 0)
        var weightSum: Float = 0
        for item in weighted {
            estimate += item.position * item.weight
            weightSum += item.weight
        }
        if weightSum > 0 {
            estimate /= weightSum
        }

        // Nonlinear least-squares style refinement.
        for _ in 0..<35 {
            var grad = SIMD3<Float>(0, 0, 0)
            var gradWeightSum: Float = 0

            for item in weighted {
                let delta = estimate - item.position
                let distance = max(simd_length(delta), 0.05)
                let error = distance - item.distance
                grad += (2.0 * error / distance) * delta * item.weight
                gradWeightSum += item.weight
            }

            guard gradWeightSum > 0 else { break }
            estimate -= 0.06 * (grad / gradWeightSum)
        }

        var residualSquares: Float = 0
        for item in weighted {
            let predicted = simd_distance(estimate, item.position)
            let err = predicted - item.distance
            residualSquares += err * err
        }
        let residual = sqrt(residualSquares / Float(weighted.count))

        let fitScore = max(0.0, min(1.0, 1.0 - (residual / 3.5)))
        let sampleScore = max(0.0, min(1.0, Float(observations.count) / 24.0))
        let confidence = fitScore * sampleScore

        guard confidence >= 0.25 else { return nil }

        return APResolvedLocation(
            position: estimate,
            confidence: confidence,
            observationCount: observations.count,
            residualErrorMeters: residual
        )
    }

    private func estimatedDistanceMeters(rssi: Double, frequencyMHz: Int) -> Float {
        let txPower = frequencyMHz > 4000 ? -45.0 : -35.0
        let n = 3.0
        let distance = pow(10.0, (txPower - rssi) / (10.0 * n))
        return Float(min(max(distance, 0.4), 25.0))
    }
}
#endif
