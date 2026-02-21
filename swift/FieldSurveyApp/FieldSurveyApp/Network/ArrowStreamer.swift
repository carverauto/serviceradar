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
        
        let timestampBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Double>
        let scannerIdBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let bssidBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let ssidBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let rssiBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Double>
        let freqBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int64>
        let securityTypeBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let isSecureBuilder = try ArrowArrayBuilders.loadBoolArrayBuilder()
        let rfVectorBuilder = try ArrowArrayBuilders.loadStringArrayBuilder()
        let xBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let yBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let zBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        let uncertaintyBuilder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        
        for sample in samples {
            timestampBuilder.append(sample.timestamp)
            scannerIdBuilder.append(sample.scannerDeviceId)
            bssidBuilder.append(sample.bssid)
            ssidBuilder.append(sample.ssid)
            rssiBuilder.append(sample.rssi)
            freqBuilder.append(Int64(sample.frequency))
            securityTypeBuilder.append(sample.securityType)
            isSecureBuilder.append(sample.isSecure)
            
            let vectorString = sample.rfVector.map { String($0) }.joined(separator: ",")
            rfVectorBuilder.append(vectorString)
            
            xBuilder.append(sample.x)
            yBuilder.append(sample.y)
            zBuilder.append(sample.z)
            uncertaintyBuilder.append(sample.uncertainty)
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
            .addColumn("x", arrowArray: try xBuilder.toHolder())
            .addColumn("y", arrowArray: try yBuilder.toHolder())
            .addColumn("z", arrowArray: try zBuilder.toHolder())
            .addColumn("uncertainty", arrowArray: try uncertaintyBuilder.toHolder())
            .finish()

        let batch: RecordBatch
        switch batchResult {
        case .success(let recordBatch):
            batch = recordBatch
        case .failure(let err):
            throw NSError(domain: "ArrowError", code: 2, userInfo: [NSLocalizedDescriptionKey: String(describing: err)])
        }

        switch ArrowWriter().toMessage(batch) {
        case .success(let dataArray):
            var combined = Data()
            for d in dataArray { combined.append(d) }
            return combined
        case .failure(let err):
            throw NSError(domain: "ArrowError", code: 1, userInfo: [NSLocalizedDescriptionKey: String(describing: err)])
        }
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
