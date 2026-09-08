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
    public let pathDiversityScore: Float
    public let strongestRSSI: Double
    public let strongestObservationPosition: SIMD3<Float>
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
        guard observations.count >= 8 else { return nil }

        // Need enough walk spread; otherwise solutions collapse to unstable points.
        let sanitized = observations
            .filter { $0.rssi.isFinite && $0.scannerPosition.isValidSurveyPosition }
            .suffix(maxObservationsPerBSSID)
        guard sanitized.count >= 8 else { return nil }

        let positions = sanitized.map(\.scannerPosition)
        let minX = positions.map(\.x).min() ?? 0
        let maxX = positions.map(\.x).max() ?? 0
        let minZ = positions.map(\.z).min() ?? 0
        let maxZ = positions.map(\.z).max() ?? 0
        let spreadX = maxX - minX
        let spreadZ = maxZ - minZ
        let spread = max(spreadX, spreadZ)
        guard spread >= 1.5 else { return nil }

        let pathDiversity = pathDiversityScore(positions: positions, spreadX: spreadX, spreadZ: spreadZ)
        guard pathDiversity >= 0.28 else { return nil }

        let strongestRSSI = sanitized.map(\.rssi).max() ?? -100.0
        let strongestCount = max(4, min(12, sanitized.count / 5))
        let sortedByRSSI = sanitized.sorted { $0.rssi > $1.rssi }
        let strongestObservations = Array(sortedByRSSI.prefix(strongestCount))
        let weakestObservations = Array(sortedByRSSI.suffix(strongestCount))

        let strongestCentroid = weightedCentroid(
            observations: strongestObservations,
            strongestRSSI: strongestRSSI,
            invertSignal: false
        )
        let weakestCentroid = weightedCentroid(
            observations: weakestObservations,
            strongestRSSI: strongestRSSI,
            invertSignal: true
        )
        let gradient = horizontalDirection(from: weakestCentroid, to: strongestCentroid)
        let strongestDistance = strongestObservations
            .map { estimatedDistanceMeters(rssi: $0.rssi, frequencyMHz: $0.frequencyMHz) }
            .sorted()
            .dropLast(max(0, strongestObservations.count - 4))
            .reduce(0, +) / Float(min(4, strongestObservations.count))
        let projectedDistance = min(max(strongestDistance * 0.55, 0.35), 3.0)

        let weighted = sanitized.map { obs -> (position: SIMD3<Float>, distance: Float, weight: Float) in
            let distance = estimatedDistanceMeters(rssi: obs.rssi, frequencyMHz: obs.frequencyMHz)
            let signalWeight = signalWeight(rssi: obs.rssi, strongestRSSI: strongestRSSI)
            return (obs.scannerPosition, distance, signalWeight)
        }

        var estimate = strongestCentroid + SIMD3<Float>(gradient.x * projectedDistance, 0, gradient.y * projectedDistance)
        estimate.y = strongestCentroid.y

        // Bounded robust refinement. RSSI-derived distances are noisy indoors,
        // so a Huber-like gradient keeps one bad multipath sample from moving
        // the AP candidate across the room.
        for _ in 0..<28 {
            var grad = SIMD3<Float>(0, 0, 0)
            var gradWeightSum: Float = 0

            for item in weighted {
                let delta = estimate - item.position
                let distance = max(simd_length(delta), 0.05)
                let error = distance - item.distance
                let robustError = max(min(error, 3.0), -3.0)
                grad += (2.0 * robustError / distance) * delta * item.weight
                gradWeightSum += item.weight
            }

            guard gradWeightSum > 0 else { break }
            estimate -= 0.035 * (grad / gradWeightSum)
            estimate.x = min(max(estimate.x, minX - 4.0), maxX + 4.0)
            estimate.z = min(max(estimate.z, minZ - 4.0), maxZ + 4.0)
        }

        var residualSquares: Float = 0
        for item in weighted {
            let predicted = simd_distance(estimate, item.position)
            let err = predicted - item.distance
            residualSquares += err * err
        }
        let residual = sqrt(residualSquares / Float(weighted.count))

        let fitScore = max(0.0, min(1.0, 1.0 - (residual / 4.5)))
        let sampleScore = max(0.0, min(1.0, Float(sanitized.count) / 32.0))
        let gradientScore = max(0.0, min(1.0, simd_distance(strongestCentroid, weakestCentroid) / 4.0))
        let confidence = fitScore * sampleScore * max(pathDiversity, gradientScore)

        guard confidence >= 0.25 else { return nil }

        return APResolvedLocation(
            position: estimate,
            confidence: confidence,
            observationCount: sanitized.count,
            residualErrorMeters: residual,
            pathDiversityScore: pathDiversity,
            strongestRSSI: strongestRSSI,
            strongestObservationPosition: strongestCentroid
        )
    }

    private func estimatedDistanceMeters(rssi: Double, frequencyMHz: Int) -> Float {
        let txPower = frequencyMHz > 4000 ? -45.0 : -35.0
        let n = 3.0
        let distance = pow(10.0, (txPower - rssi) / (10.0 * n))
        return Float(min(max(distance, 0.4), 25.0))
    }

    private func signalWeight(rssi: Double, strongestRSSI: Double) -> Float {
        let relative = max(-35.0, min(0.0, rssi - strongestRSSI))
        return Float(pow(10.0, relative / 18.0)).clamped(to: 0.08...1.0)
    }

    private func weightedCentroid(
        observations: [APPositionObservation],
        strongestRSSI: Double,
        invertSignal: Bool
    ) -> SIMD3<Float> {
        var centroid = SIMD3<Float>(0, 0, 0)
        var weightSum: Float = 0

        for observation in observations {
            let base = signalWeight(rssi: observation.rssi, strongestRSSI: strongestRSSI)
            let weight = invertSignal ? max(0.08, 1.0 - base) : base
            centroid += observation.scannerPosition * weight
            weightSum += weight
        }

        guard weightSum > 0 else { return observations.first?.scannerPosition ?? SIMD3<Float>(0, 0, 0) }
        return centroid / weightSum
    }

    private func horizontalDirection(from start: SIMD3<Float>, to end: SIMD3<Float>) -> SIMD2<Float> {
        let delta = SIMD2<Float>(end.x - start.x, end.z - start.z)
        let length = simd_length(delta)
        guard length > 0.05 else { return SIMD2<Float>(0, 0) }
        return delta / length
    }

    private func pathDiversityScore(positions: [SIMD3<Float>], spreadX: Float, spreadZ: Float) -> Float {
        guard !positions.isEmpty else { return 0 }
        let occupancy = Set(positions.map { position in
            let xBucket = Int(floor((position.x / max(spreadX, 0.5)) * 4.0))
            let zBucket = Int(floor((position.z / max(spreadZ, 0.5)) * 4.0))
            return "\(xBucket):\(zBucket)"
        })
        let occupancyScore = min(1.0, Float(occupancy.count) / 8.0)
        let balanceScore = min(spreadX, spreadZ) / max(max(spreadX, spreadZ), 0.1)
        return max(0.0, min(1.0, 0.65 * occupancyScore + 0.35 * balanceScore))
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension SIMD3 where Scalar == Float {
    var isValidSurveyPosition: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
#endif
