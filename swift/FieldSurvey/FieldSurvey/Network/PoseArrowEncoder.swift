import Foundation
import Arrow
import simd

public struct FieldSurveyPoseSample: Sendable {
    public let scannerDeviceID: String
    public let capturedAtUnixNanos: Int64
    public let capturedAtMonotonicNanos: UInt64?
    public let position: SIMD3<Float>
    public let orientation: simd_quatf
    public let latitude: Double?
    public let longitude: Double?
    public let altitude: Double?
    public let accuracyMeters: Float?
    public let trackingQuality: String?
}

public struct PoseArrowEncoder: Sendable {
    public init() {}

    public func encode(samples: [FieldSurveyPoseSample]) throws -> Data {
        let scannerIDBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let unixNanosBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int64>
        let monotonicNanosBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<UInt64>
        let xBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let yBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let zBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let qxBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let qyBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let qzBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let qwBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let latitudeBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Double>
        let longitudeBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Double>
        let altitudeBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Double>
        let accuracyBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let trackingQualityBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()

        for sample in samples {
            scannerIDBuilder.append(sample.scannerDeviceID)
            unixNanosBuilder.append(sample.capturedAtUnixNanos)
            monotonicNanosBuilder.append(sample.capturedAtMonotonicNanos)
            xBuilder.append(sample.position.x)
            yBuilder.append(sample.position.y)
            zBuilder.append(sample.position.z)
            qxBuilder.append(sample.orientation.vector.x)
            qyBuilder.append(sample.orientation.vector.y)
            qzBuilder.append(sample.orientation.vector.z)
            qwBuilder.append(sample.orientation.vector.w)
            latitudeBuilder.append(sample.latitude)
            longitudeBuilder.append(sample.longitude)
            altitudeBuilder.append(sample.altitude)
            accuracyBuilder.append(sample.accuracyMeters)
            trackingQualityBuilder.append(sample.trackingQuality)
        }

        let batchResult = RecordBatch.Builder()
            .addColumn("scanner_device_id", arrowArray: try scannerIDBuilder.toHolder())
            .addColumn("captured_at_unix_nanos", arrowArray: try unixNanosBuilder.toHolder())
            .addColumn("captured_at_monotonic_nanos", arrowArray: try monotonicNanosBuilder.toHolder())
            .addColumn("x", arrowArray: try xBuilder.toHolder())
            .addColumn("y", arrowArray: try yBuilder.toHolder())
            .addColumn("z", arrowArray: try zBuilder.toHolder())
            .addColumn("qx", arrowArray: try qxBuilder.toHolder())
            .addColumn("qy", arrowArray: try qyBuilder.toHolder())
            .addColumn("qz", arrowArray: try qzBuilder.toHolder())
            .addColumn("qw", arrowArray: try qwBuilder.toHolder())
            .addColumn("latitude", arrowArray: try latitudeBuilder.toHolder())
            .addColumn("longitude", arrowArray: try longitudeBuilder.toHolder())
            .addColumn("altitude", arrowArray: try altitudeBuilder.toHolder())
            .addColumn("accuracy_m", arrowArray: try accuracyBuilder.toHolder())
            .addColumn("tracking_quality", arrowArray: try trackingQualityBuilder.toHolder())
            .finish()

        let batch: RecordBatch
        switch batchResult {
        case .success(let recordBatch):
            batch = recordBatch
        case .failure(let error):
            throw NSError(
                domain: "PoseArrowEncoder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(describing: error)]
            )
        }

        let writerInfo = ArrowWriter.Info(.recordbatch, schema: batch.schema, batches: [batch])
        switch ArrowWriter().writeStreaming(writerInfo) {
        case .success(let data):
            return data
        case .failure(let error):
            throw NSError(
                domain: "PoseArrowEncoder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(describing: error)]
            )
        }
    }
}
