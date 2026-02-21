import Foundation
import Arrow
import os.log
import Combine

/// A high-performance Arrow IPC streamer that builds valid RecordBatches 
/// using the apache/arrow-swift package instead of mock byte layouts.
public class ArrowStreamer {
    private let logger = Logger(subsystem: "com.serviceradar.fieldsurvey", category: "ArrowStreamer")
    
    // We explicitly configure the session to prefer HTTP/3 (QUIC) to minimize latency 
    // and avoid head-of-line blocking during continuous, high-velocity telemetry streaming.
    private lazy var quicSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        // HTTP/3 uses QUIC. By setting assumesHTTP3Capable, iOS will attempt UDP QUIC immediately 
        // without waiting for an Alt-Svc upgrade header over a TCP/HTTP2 connection.
        config.assumesHTTP3Capable = true
        return URLSession(configuration: config)
    }()
    
    public init() {}
    
    /// Encodes a batch of cyber-physical RF samples into an Apache Arrow IPC payload.
    /// Uses Arrow's columnar memory layout for zero-copy deserialization by the Rust backend.
    public func encodeBatch(samples: [SurveySample]) throws -> Data {
        logger.debug("Encoding \(samples.count) samples to Arrow IPC Layout")
        
        // Define the Arrow Schema representing the causal spatial join fields
        let schemaBuilder = ArrowSchema.Builder()
        let schema = schemaBuilder
            .addField("timestamp", type: ArrowType.float64, isNullable: false)
            .addField("bssid", type: ArrowType.string, isNullable: false)
            .addField("ssid", type: ArrowType.string, isNullable: false)
            .addField("rssi", type: ArrowType.float64, isNullable: false)
            .addField("frequency", type: ArrowType.int64, isNullable: false)
            .addField("securityType", type: ArrowType.string, isNullable: false)
            .addField("isSecure", type: ArrowType.boolean, isNullable: false)
            .addField("x", type: ArrowType.float32, isNullable: false)
            .addField("y", type: ArrowType.float32, isNullable: false)
            .addField("z", type: ArrowType.float32, isNullable: false)
            .addField("uncertainty", type: ArrowType.float32, isNullable: false)
            .finish()

        let timestampBuilder = try NumberArrayBuilder<Double>()
        let bssidBuilder = try StringArrayBuilder()
        let ssidBuilder = try StringArrayBuilder()
        let rssiBuilder = try NumberArrayBuilder<Double>()
        let freqBuilder = try NumberArrayBuilder<Int64>()
        let securityTypeBuilder = try StringArrayBuilder()
        let isSecureBuilder = try BoolArrayBuilder()
        let xBuilder = try NumberArrayBuilder<Float>()
        let yBuilder = try NumberArrayBuilder<Float>()
        let zBuilder = try NumberArrayBuilder<Float>()
        let uncertaintyBuilder = try NumberArrayBuilder<Float>()
        
        // Populate columnar data arrays
        for sample in samples {
            timestampBuilder.append(sample.timestamp)
            bssidBuilder.append(sample.bssid)
            ssidBuilder.append(sample.ssid)
            rssiBuilder.append(sample.rssi)
            freqBuilder.append(Int64(sample.frequency))
            securityTypeBuilder.append(sample.securityType)
            isSecureBuilder.append(sample.isSecure)
            xBuilder.append(sample.x)
            yBuilder.append(sample.y)
            zBuilder.append(sample.z)
            uncertaintyBuilder.append(sample.uncertainty)
        }
        
        let recordBatchBuilder = RecordBatch.Builder()
        let batch = try recordBatchBuilder
            .addColumn("timestamp", array: try timestampBuilder.finish())
            .addColumn("bssid", array: try bssidBuilder.finish())
            .addColumn("ssid", array: try ssidBuilder.finish())
            .addColumn("rssi", array: try rssiBuilder.finish())
            .addColumn("frequency", array: try freqBuilder.finish())
            .addColumn("securityType", array: try securityTypeBuilder.finish())
            .addColumn("isSecure", array: try isSecureBuilder.finish())
            .addColumn("x", array: try xBuilder.finish())
            .addColumn("y", array: try yBuilder.finish())
            .addColumn("z", array: try zBuilder.finish())
            .addColumn("uncertainty", array: try uncertaintyBuilder.finish())
            .finish(schema: schema)

        let writer = ArrowWriter()
        let data = try writer.toStream(batch)
        return data
    }
    
    /// Streams the encoded Arrow IPC payload over UDP QUIC (HTTP/3).
    /// QUIC eliminates TCP head-of-line blocking which is crucial for high-velocity IoT/RF telemetry.
    public func streamToBackend(payload: Data, sessionID: String) {
        logger.info("Streaming \(payload.count) bytes to backend via UDP QUIC (HTTP/3) (Topic: sr.survey.\(sessionID).arrow)")
        
        // The real networking call utilizing HTTP/POST over QUIC to the proxy
        guard let url = URL(string: "https://serviceradar-api.internal/v1/stream/\(sessionID)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.apache.arrow.stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        
        let task = quicSession.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                self?.logger.error("QUIC Stream failed: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                self?.logger.error("QUIC Stream rejected by server: HTTP \(httpResponse.statusCode)")
            } else {
                self?.logger.debug("Successfully pushed IPC payload over QUIC")
            }
        }
        task.resume()
    }
    
    /// Compresses and saves the entire batch locally for offline/bulk sync later
    public func compressForOfflineUpload(payload: Data, filename: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("\(filename).arrow.lzfse")
        
        // Zstandard (zstd) natively requires C headers bridged, Apple's high-perf native is LZFSE. 
        // Applying compression for offline syncing.
        let compressed = try (payload as NSData).compressed(using: .lzfse)
        
        logger.info("Compressing and saving batch to \(fileURL.lastPathComponent) for offline sync.")
        try compressed.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
