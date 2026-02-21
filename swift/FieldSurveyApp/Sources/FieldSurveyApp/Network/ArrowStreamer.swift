import Foundation
import Arrow
import os.log
import Combine

/// A high-performance Arrow IPC streamer that builds valid RecordBatches 
/// using the apache/arrow-swift package instead of mock byte layouts.
public class ArrowStreamer {
    private let logger = Logger(subsystem: "com.serviceradar.fieldsurvey", category: "ArrowStreamer")
    
    // Use a persistent WebSocket connection over standard TCP/443. 
    // This guarantees compatibility with enterprise firewalls and standard Kubernetes Ingress, 
    // while allowing us to stream Arrow IPC frames directly into Elixir Phoenix Channels or a NATS WS proxy.
    private var webSocketTask: URLSessionWebSocketTask?
    
    public init() {}
    
    /// Establishes a persistent WebSocket connection to the ServiceRadar ingestion pipeline.
    public func connect(sessionID: String) {
        guard let url = URL(string: "wss://serviceradar-api.internal/v1/stream/\(sessionID)") else { return }
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        logger.info("Established WebSocket connection to stream: \(url.absoluteString)")
        
        // Setup listener for potential server acknowledgments or backpressure signals
        listenForMessages()
    }
    
    public func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        logger.info("WebSocket connection closed.")
    }
    
    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .failure(let error):
                self?.logger.error("WebSocket connection error: \(error.localizedDescription)")
            case .success(let message):
                // Handle NATS/Phoenix ACKs if necessary
                self?.logger.debug("Received ACK from server: \(String(describing: message))")
                self?.listenForMessages() // recursively listen
            }
        }
    }
    
    /// Encodes a batch of cyber-physical RF samples into an Apache Arrow IPC payload.
    /// Uses Arrow's columnar memory layout for zero-copy deserialization by the Rust backend.
    public func encodeBatch(samples: [SurveySample]) throws -> Data {
        logger.debug("Encoding \(samples.count) samples to Arrow IPC Layout")
        
        // Define the Arrow Schema representing the causal spatial join fields
        let schemaBuilder = ArrowSchema.Builder()
        let schema = schemaBuilder
            .addField("timestamp", type: ArrowType.float64, isNullable: false)
            .addField("scannerDeviceId", type: ArrowType.string, isNullable: false)
            .addField("bssid", type: ArrowType.string, isNullable: false)
            .addField("ssid", type: ArrowType.string, isNullable: false)
            .addField("rssi", type: ArrowType.float64, isNullable: false)
            .addField("frequency", type: ArrowType.int64, isNullable: false)
            .addField("securityType", type: ArrowType.string, isNullable: false)
            .addField("isSecure", type: ArrowType.boolean, isNullable: false)
            // rfVector is a List<Double>
            .addField("rfVector", type: ArrowType.list(ArrowType.float64), isNullable: false)
            .addField("x", type: ArrowType.float32, isNullable: false)
            .addField("y", type: ArrowType.float32, isNullable: false)
            .addField("z", type: ArrowType.float32, isNullable: false)
            .addField("uncertainty", type: ArrowType.float32, isNullable: false)
            .finish()

        let timestampBuilder = try NumberArrayBuilder<Double>()
        let scannerIdBuilder = try StringArrayBuilder()
        let bssidBuilder = try StringArrayBuilder()
        let ssidBuilder = try StringArrayBuilder()
        let rssiBuilder = try NumberArrayBuilder<Double>()
        let freqBuilder = try NumberArrayBuilder<Int64>()
        let securityTypeBuilder = try StringArrayBuilder()
        let isSecureBuilder = try BoolArrayBuilder()
        
        let rfVectorBuilder = try ListArrayBuilder<Double>(ArrowType.float64)
        
        let xBuilder = try NumberArrayBuilder<Float>()
        let yBuilder = try NumberArrayBuilder<Float>()
        let zBuilder = try NumberArrayBuilder<Float>()
        let uncertaintyBuilder = try NumberArrayBuilder<Float>()
        
        // Populate columnar data arrays
        for sample in samples {
            timestampBuilder.append(sample.timestamp)
            scannerIdBuilder.append(sample.scannerDeviceId)
            bssidBuilder.append(sample.bssid)
            ssidBuilder.append(sample.ssid)
            rssiBuilder.append(sample.rssi)
            freqBuilder.append(Int64(sample.frequency))
            securityTypeBuilder.append(sample.securityType)
            isSecureBuilder.append(sample.isSecure)
            
            // Build the variable-length list array for this specific row's rfVector
            rfVectorBuilder.append(sample.rfVector)
            
            xBuilder.append(sample.x)
            yBuilder.append(sample.y)
            zBuilder.append(sample.z)
            uncertaintyBuilder.append(sample.uncertainty)
        }
        
        let recordBatchBuilder = RecordBatch.Builder()
        let batch = try recordBatchBuilder
            .addColumn("timestamp", array: try timestampBuilder.finish())
            .addColumn("scannerDeviceId", array: try scannerIdBuilder.finish())
            .addColumn("bssid", array: try bssidBuilder.finish())
            .addColumn("ssid", array: try ssidBuilder.finish())
            .addColumn("rssi", array: try rssiBuilder.finish())
            .addColumn("frequency", array: try freqBuilder.finish())
            .addColumn("securityType", array: try securityTypeBuilder.finish())
            .addColumn("isSecure", array: try isSecureBuilder.finish())
            .addColumn("rfVector", array: try rfVectorBuilder.finish())
            .addColumn("x", array: try xBuilder.finish())
            .addColumn("y", array: try yBuilder.finish())
            .addColumn("z", array: try zBuilder.finish())
            .addColumn("uncertainty", array: try uncertaintyBuilder.finish())
            .finish(schema: schema)

        let writer = ArrowWriter()
        let data = try writer.toStream(batch)
        return data
    }
    
    /// Streams the encoded Arrow IPC payload over a persistent WebSocket connection.
    /// This provides ultra-low latency streaming natively compatible with NATS and Phoenix Channels.
    public func streamToBackend(payload: Data, sessionID: String) {
        guard let webSocketTask = webSocketTask else {
            logger.error("Attempted to stream Arrow payload without an active WebSocket connection.")
            return
        }
        
        logger.info("Streaming \(payload.count) bytes to backend via WebSocket (Topic: sr.survey.\(sessionID).arrow)")
        
        let message = URLSessionWebSocketTask.Message.data(payload)
        
        webSocketTask.send(message) { [weak self] error in
            if let error = error {
                self?.logger.error("WebSocket Stream failed: \(error.localizedDescription)")
            } else {
                self?.logger.debug("Successfully pushed IPC payload over WebSocket.")
            }
        }
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
