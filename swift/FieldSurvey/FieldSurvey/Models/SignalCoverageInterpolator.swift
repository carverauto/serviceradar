import Foundation
import simd

public struct SignalCoveragePrediction: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let position: SIMD3<Float>
    public let rssi: Double
    public let confidence: Double
    public let nearestSampleDistance: Float
}

public enum SignalCoverageInterpolator {
    public static func coverageGrid(
        points: [WiFiHeatmapPoint],
        minX: Float,
        maxX: Float,
        minZ: Float,
        maxZ: Float,
        preferredCellSize: Float = 0.45
    ) -> [SignalCoveragePrediction] {
        let validPoints = points.filter {
            $0.position.isValidCoveragePosition && $0.rssi.isFinite
        }
        guard validPoints.count >= 3,
              minX.isFinite,
              maxX.isFinite,
              minZ.isFinite,
              maxZ.isFinite,
              maxX > minX,
              maxZ > minZ else {
            return []
        }

        let models = trainedModels(from: validPoints)
        guard !models.isEmpty else { return [] }

        let cellSize = max(preferredCellSize, 0.22)
        let columns = min(max(Int(ceil((maxX - minX) / cellSize)), 10), 56)
        let rows = min(max(Int(ceil((maxZ - minZ) / cellSize)), 10), 56)
        let stepX = (maxX - minX) / Float(columns)
        let stepZ = (maxZ - minZ) / Float(rows)

        var grid: [SignalCoveragePrediction] = []
        grid.reserveCapacity(columns * rows)

        for row in 0..<rows {
            for column in 0..<columns {
                let x = minX + (Float(column) + 0.5) * stepX
                let z = minZ + (Float(row) + 0.5) * stepZ
                let query = SIMD2<Double>(Double(x), Double(z))

                var best: SignalCoveragePrediction?
                for model in models {
                    guard let prediction = model.predict(query: query, y: validPoints[0].y) else { continue }
                    if best == nil || prediction.rssi > best!.rssi {
                        best = prediction
                    }
                }

                if let best {
                    grid.append(best)
                }
            }
        }

        return grid
    }

    private static func trainedModels(from points: [WiFiHeatmapPoint]) -> [GaussianProcessModel] {
        Dictionary(grouping: points, by: \.bssid).values
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return (lhs.map(\.timestamp).max() ?? 0) > (rhs.map(\.timestamp).max() ?? 0)
                }
                return lhs.count > rhs.count
            }
            .prefix(8)
            .compactMap { apPoints in
                let samples = bucketedTrainingSamples(apPoints)
                guard samples.count >= 3 else { return nil }
                return GaussianProcessModel(samples: samples)
            }
    }

    private static func bucketedTrainingSamples(_ points: [WiFiHeatmapPoint]) -> [TrainingSample] {
        struct Accumulator {
            var x: Double = 0
            var z: Double = 0
            var y: Float = 0
            var rssi: Double = 0
            var count: Int = 0
            var latestTimestamp: TimeInterval = 0
        }

        let cellSize: Float = 0.45
        var buckets: [String: Accumulator] = [:]

        for point in points {
            guard let xi = bucketIndex(point.x, cellSize: cellSize),
                  let zi = bucketIndex(point.z, cellSize: cellSize) else {
                continue
            }

            let key = "\(xi):\(zi)"
            var acc = buckets[key] ?? Accumulator()
            acc.x += Double(point.x)
            acc.z += Double(point.z)
            acc.y += point.y
            acc.rssi += max(-100.0, min(-20.0, point.rssi))
            acc.count += 1
            acc.latestTimestamp = max(acc.latestTimestamp, point.timestamp)
            buckets[key] = acc
        }

        let samples = buckets.values.compactMap { acc -> TrainingSample? in
            guard acc.count > 0 else { return nil }
            let count = Double(acc.count)
            return TrainingSample(
                point: SIMD2<Double>(acc.x / count, acc.z / count),
                y: acc.y / Float(acc.count),
                rssi: acc.rssi / count,
                latestTimestamp: acc.latestTimestamp
            )
        }

        return samples
            .sorted { $0.latestTimestamp > $1.latestTimestamp }
            .prefix(96)
            .map { $0 }
    }

    private static func bucketIndex(_ value: Float, cellSize: Float) -> Int? {
        guard value.isFinite, cellSize.isFinite, cellSize > 0 else { return nil }
        let bucket = (value / cellSize).rounded()
        guard bucket.isFinite,
              bucket >= Float(Int.min),
              bucket <= Float(Int.max) else {
            return nil
        }
        return Int(bucket)
    }
}

private struct TrainingSample {
    let point: SIMD2<Double>
    let y: Float
    let rssi: Double
    let latestTimestamp: TimeInterval
}

private struct GaussianProcessModel {
    private let samples: [TrainingSample]
    private let mean: Double
    private let alpha: [Double]
    private let cholesky: [[Double]]
    private let signalVariance: Double = 100.0
    private let noiseVariance: Double = 16.0
    private let lengthScale: Double

    init?(samples: [TrainingSample]) {
        guard samples.count >= 3 else { return nil }
        self.samples = samples
        let sampleMean = samples.map(\.rssi).reduce(0, +) / Double(samples.count)
        self.mean = sampleMean
        self.lengthScale = GaussianProcessModel.lengthScale(for: samples)

        var kernel = Array(
            repeating: Array(repeating: 0.0, count: samples.count),
            count: samples.count
        )

        for row in samples.indices {
            for column in 0...row {
                let covariance = GaussianProcessModel.rbf(
                    samples[row].point,
                    samples[column].point,
                    lengthScale: lengthScale,
                    signalVariance: signalVariance
                ) + (row == column ? noiseVariance : 0.0)
                kernel[row][column] = covariance
                kernel[column][row] = covariance
            }
        }

        guard let factor = GaussianProcessModel.cholesky(kernel) else { return nil }
        self.cholesky = factor
        let centeredRSSI = samples.map { $0.rssi - sampleMean }
        self.alpha = GaussianProcessModel.solveCholesky(factor, centeredRSSI)
    }

    func predict(query: SIMD2<Double>, y: Float) -> SignalCoveragePrediction? {
        guard query.x.isFinite, query.y.isFinite else { return nil }

        let covariance = samples.map {
            GaussianProcessModel.rbf(
                query,
                $0.point,
                lengthScale: lengthScale,
                signalVariance: signalVariance
            )
        }

        let predictedRSSI = mean + zip(covariance, alpha).map(*).reduce(0, +)
        let solved = GaussianProcessModel.solveLowerTriangular(cholesky, covariance)
        let variance = max(signalVariance - solved.map { $0 * $0 }.reduce(0, +), 0.0)
        let nearestDistance = nearestSampleDistance(to: query)
        let uncertaintyPenalty = min(sqrt(variance) / 22.0, 1.0)
        let distancePenalty = min(max(nearestDistance - 1.2, 0.0) / 5.0, 1.0)
        let confidence = max(0.0, 1.0 - max(uncertaintyPenalty, distancePenalty))

        return SignalCoveragePrediction(
            position: SIMD3<Float>(Float(query.x), y, Float(query.y)),
            rssi: max(-100.0, min(-20.0, predictedRSSI)),
            confidence: confidence,
            nearestSampleDistance: Float(nearestDistance)
        )
    }

    private func nearestSampleDistance(to query: SIMD2<Double>) -> Double {
        samples
            .map { simd_distance(query, $0.point) }
            .min() ?? .greatestFiniteMagnitude
    }

    private static func lengthScale(for samples: [TrainingSample]) -> Double {
        guard samples.count > 1 else { return 2.0 }
        var distances: [Double] = []
        for index in samples.indices {
            let point = samples[index].point
            let nearest = samples.indices
                .filter { $0 != index }
                .map { simd_distance(point, samples[$0].point) }
                .min()
            if let nearest, nearest.isFinite, nearest > 0 {
                distances.append(nearest)
            }
        }

        let medianNearest = distances.sorted().dropFirst(distances.count / 2).first ?? 1.0
        return min(max(medianNearest * 3.5, 1.2), 4.5)
    }

    private static func rbf(
        _ lhs: SIMD2<Double>,
        _ rhs: SIMD2<Double>,
        lengthScale: Double,
        signalVariance: Double
    ) -> Double {
        let dx = lhs.x - rhs.x
        let dz = lhs.y - rhs.y
        let distanceSquared = dx * dx + dz * dz
        return signalVariance * exp(-distanceSquared / (2.0 * lengthScale * lengthScale))
    }

    private static func cholesky(_ matrix: [[Double]]) -> [[Double]]? {
        let count = matrix.count
        var lower = Array(repeating: Array(repeating: 0.0, count: count), count: count)

        for row in 0..<count {
            for column in 0...row {
                var sum = matrix[row][column]
                for k in 0..<column {
                    sum -= lower[row][k] * lower[column][k]
                }

                if row == column {
                    guard sum > 0, sum.isFinite else { return nil }
                    lower[row][column] = sqrt(sum)
                } else {
                    guard lower[column][column] != 0 else { return nil }
                    lower[row][column] = sum / lower[column][column]
                }
            }
        }

        return lower
    }

    private static func solveCholesky(_ lower: [[Double]], _ vector: [Double]) -> [Double] {
        let y = solveLowerTriangular(lower, vector)
        return solveUpperTriangular(lower, y)
    }

    private static func solveLowerTriangular(_ lower: [[Double]], _ vector: [Double]) -> [Double] {
        var result = Array(repeating: 0.0, count: vector.count)
        for row in vector.indices {
            var sum = vector[row]
            for column in 0..<row {
                sum -= lower[row][column] * result[column]
            }
            result[row] = sum / lower[row][row]
        }
        return result
    }

    private static func solveUpperTriangular(_ lower: [[Double]], _ vector: [Double]) -> [Double] {
        var result = Array(repeating: 0.0, count: vector.count)
        for row in stride(from: vector.count - 1, through: 0, by: -1) {
            var sum = vector[row]
            for column in (row + 1)..<vector.count {
                sum -= lower[column][row] * result[column]
            }
            result[row] = sum / lower[row][row]
        }
        return result
    }
}

private extension SIMD3 where Scalar == Float {
    var isValidCoveragePosition: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
