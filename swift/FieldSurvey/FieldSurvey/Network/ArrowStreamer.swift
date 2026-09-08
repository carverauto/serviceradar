import Foundation
import Arrow

/// A high-performance Arrow IPC streamer that builds valid RecordBatches 
/// using the apache/arrow-swift package instead of mock byte layouts.
public struct ArrowStreamer: Sendable {
    public init() {}

    /// Encodes a batch of cyber-physical RF samples into an Apache Arrow IPC payload.
    /// Uses Arrow's columnar memory layout for zero-copy deserialization by the Rust backend.
    public func encodeBatch(samples: [SurveySample]) throws -> Data {
        
        let timestampBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Double>
        let scannerIdBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let bssidBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let ssidBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let rssiBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Double>
        let freqBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int64>
        let securityTypeBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let isSecureBuilder = try ArrowArrayBuilders.loadBoolArrayBuilder()
        let rfVectorBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let bleVectorBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let xBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let yBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let zBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let latBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Double>
        let lonBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Double>
        let uncertaintyBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let ipAddressBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let hostnameBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        
        for sample in samples {
            timestampBuilder.append(sample.timestamp)
            scannerIdBuilder.append(sample.scannerDeviceId)
            bssidBuilder.append(sample.bssid)
            ssidBuilder.append(sample.ssid)
            rssiBuilder.append(sample.rssi)
            freqBuilder.append(Int64(sample.frequency))
            securityTypeBuilder.append(sample.securityType)
            isSecureBuilder.append(sample.isSecure)
            
            let normalizedRF = SurveySample.normalizeRFVector(sample.rfVector)
            rfVectorBuilder.append(Self.vectorCSV(normalizedRF))

            let normalizedBLE = SurveySample.normalizeBLEVector(sample.bleVector)
            bleVectorBuilder.append(Self.vectorCSV(normalizedBLE))
            
            xBuilder.append(sample.x)
            yBuilder.append(sample.y)
            zBuilder.append(sample.z)
            latBuilder.append(sample.latitude)
            lonBuilder.append(sample.longitude)
            uncertaintyBuilder.append(sample.uncertainty)
            ipAddressBuilder.append(sample.ipAddress)
            hostnameBuilder.append(sample.hostname)
        }
        
        let recordBatchBuilder = RecordBatch.Builder()
        let batchResult = recordBatchBuilder
            .addColumn("timestamp", arrowArray: try timestampBuilder.toHolder())
            .addColumn("scannerDeviceId", arrowArray: try scannerIdBuilder.toHolder())
            .addColumn("bssid", arrowArray: try bssidBuilder.toHolder())
            .addColumn("ssid", arrowArray: try ssidBuilder.toHolder())
            .addColumn("rssi", arrowArray: try rssiBuilder.toHolder())
            .addColumn("frequency", arrowArray: try freqBuilder.toHolder())
            .addColumn("securityType", arrowArray: try securityTypeBuilder.toHolder())
            .addColumn("isSecure", arrowArray: try isSecureBuilder.toHolder())
            .addColumn("rfVector", arrowArray: try rfVectorBuilder.toHolder())
            .addColumn("bleVector", arrowArray: try bleVectorBuilder.toHolder())
            .addColumn("x", arrowArray: try xBuilder.toHolder())
            .addColumn("y", arrowArray: try yBuilder.toHolder())
            .addColumn("z", arrowArray: try zBuilder.toHolder())
            .addColumn("latitude", arrowArray: try latBuilder.toHolder())
            .addColumn("longitude", arrowArray: try lonBuilder.toHolder())
            .addColumn("uncertainty", arrowArray: try uncertaintyBuilder.toHolder())
            .addColumn("ipAddress", arrowArray: try ipAddressBuilder.toHolder())
            .addColumn("hostname", arrowArray: try hostnameBuilder.toHolder())
            .finish()

        let batch: RecordBatch
        switch batchResult {
        case .success(let recordBatch):
            batch = recordBatch
        case .failure(let err):
            throw NSError(domain: "ArrowError", code: 2, userInfo: [NSLocalizedDescriptionKey: String(describing: err)])
        }

        let writerInfo = ArrowWriter.Info(.recordbatch, schema: batch.schema, batches: [batch])
        switch ArrowWriter().writeStreaming(writerInfo) {
        case .success(let data):
            return data
        case .failure(let err):
            throw NSError(domain: "ArrowError", code: 1, userInfo: [NSLocalizedDescriptionKey: String(describing: err)])
        }
    }
    
    private static func vectorCSV(_ values: [Double]) -> String {
        values.map { String(Float($0)) }.joined(separator: ",")
    }
    
    /// Compresses and saves the entire batch locally for offline/bulk sync later
    public func compressForOfflineUpload(payload: Data, filename: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("\(filename).arrow.lzfse")
        
        // Zstandard (zstd) natively requires C headers bridged, Apple's high-perf native is LZFSE. 
        // Applying compression for offline syncing.
        let compressed = try (payload as NSData).compressed(using: .lzfse)
        
        try compressed.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
