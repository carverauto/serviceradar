import Foundation
import Network
import os.log

public struct RPerfSummary: Codable, Sendable {
    public var duration: Double = 0
    public var bytes_sent: UInt64 = 0
    public var bytes_received: UInt64 = 0
    public var bits_per_second: Double = 0
    public var packets_sent: UInt64 = 0
    public var packets_received: UInt64 = 0
    public var packets_lost: UInt64 = 0
    public var loss_percent: Double = 0
    public var jitter_ms: Double = 0
    public init() {}
}

public struct RPerfResult: Codable, Sendable {
    public var success: Bool
    public var error: String?
    public var results_json: String
    public var summary: RPerfSummary
    
    public init(success: Bool, error: String? = nil, results_json: String = "", summary: RPerfSummary = RPerfSummary()) {
        self.success = success
        self.error = error
        self.results_json = results_json
        self.summary = summary
    }
}

public enum RPerfProtocol: String, Sendable {
    case tcp
    case udp
}

final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool = false
    func exchange(with newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}

@available(macOS 11.0, iOS 14.0, *)
public actor RPerfRunner {
    public let targetAddress: String
    public let port: UInt16
    public let testProtocol: RPerfProtocol
    public let reverse: Bool
    public let bandwidth: UInt64
    public let duration: Double
    public let parallel: Int
    public let length: Int
    public let sendInterval: Double
    
    private let logger = Logger(subsystem: "com.serviceradar.rperfclient", category: "RPerfRunner")

    public init(targetAddress: String, port: UInt16, testProtocol: RPerfProtocol = .tcp, reverse: Bool = false, bandwidth: UInt64 = 1_000_000, duration: Double = 5.0, parallel: Int = 1, length: Int = 32768, sendInterval: Double = 0.05) {
        self.targetAddress = targetAddress
        self.port = port
        self.testProtocol = testProtocol
        self.reverse = reverse
        self.bandwidth = bandwidth
        self.duration = duration
        self.parallel = parallel
        self.length = max(length, 16)
        self.sendInterval = sendInterval
    }
    
    public func runTest() async throws -> RPerfResult {
        logger.info("Starting rperf test to \(self.targetAddress):\(self.port)")
        
        let controlConn = NWConnection(host: NWEndpoint.Host(targetAddress), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let controlStream = AsyncNWConnection(connection: controlConn)
        try await controlStream.start()
        
        let testId = UUID()
        let testIdBytes = withUnsafeBytes(of: testId.uuid) { Array($0) }
        
        var config: [String: Any] = [
            "kind": "configuration",
            "family": testProtocol.rawValue,
            "role": reverse ? "upload" : "download", // Server's role
            "test_id": testIdBytes,
            "streams": parallel,
            "duration": duration,
            "length": length
        ]
        
        if reverse { // Server uploads
            config["bandwidth"] = bandwidth
            config["send_interval"] = sendInterval
            config["send_buffer"] = length * 2
        } else { // Server downloads
            config["receive_buffer"] = length * 2
        }
        
        var listeners: [NWListener] = []
        var streamPorts: [UInt16] = []
        
        if reverse {
            for _ in 0..<parallel {
                let listener = try NWListener(using: testProtocol == .tcp ? .tcp : .udp)
                let boundPort = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                    let resumed = AtomicBool()
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if let port = listener.port?.rawValue, !resumed.exchange(with: true) {
                                continuation.resume(returning: port)
                            }
                        case .failed(let err):
                            if !resumed.exchange(with: true) {
                                continuation.resume(throwing: err)
                            }
                        case .cancelled:
                            if !resumed.exchange(with: true) {
                                continuation.resume(throwing: CancellationError())
                            }
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { newConn in
                        newConn.start(queue: .global())
                        Task { await self.consumeData(connection: newConn) }
                    }
                    listener.start(queue: .global())
                }
                listeners.append(listener)
                streamPorts.append(boundPort)
            }
            config["stream_ports"] = streamPorts
        }
        
        try await controlStream.send(json: config)
        
        if !reverse {
            let connectMsg = try await controlStream.receiveJSON()
            guard connectMsg["kind"] as? String == "connect",
                  let ports = connectMsg["stream_ports"] as? [UInt16] else {
                throw URLError(.badServerResponse)
            }
            streamPorts = ports
        }
        
        var streamConnections: [AsyncNWConnection] = []
        if !reverse {
            for port in streamPorts {
                let conn = NWConnection(host: NWEndpoint.Host(targetAddress), port: NWEndpoint.Port(rawValue: port)!, using: testProtocol == .tcp ? .tcp : .udp)
                let asyncConn = AsyncNWConnection(connection: conn)
                try await asyncConn.start()
                streamConnections.append(asyncConn)
            }
        }
        
        try await controlStream.send(json: ["kind": "begin"])
        
        while true {
            let msg = try await controlStream.receiveJSON()
            if msg["kind"] as? String == "ready" {
                break
            }
        }
        
        let testStartTime = Date()
        
        if !reverse {
            let payload = Data(testIdBytes) + Data(repeating: 0, count: length - 16)
            for conn in streamConnections {
                Task {
                    while Date().timeIntervalSince(testStartTime) < duration {
                        try? await conn.send(data: payload)
                        if testProtocol == .udp {
                            try? await Task.sleep(nanoseconds: UInt64(sendInterval * 1_000_000_000))
                        }
                    }
                }
            }
        }
        
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        
        for conn in streamConnections {
            conn.cancel()
        }
        for listener in listeners {
            listener.cancel()
        }
        
        try await controlStream.send(json: ["kind": "end"])
        
        var finalJson: [String: Any]?
        var rawJsonString: String = ""
        while true {
            let (msg, raw) = try await controlStream.receiveJSONAndString()
            if msg["kind"] as? String == "results" || msg["summary"] != nil {
                finalJson = msg
                rawJsonString = raw
                break
            }
        }
        
        controlStream.cancel()
        
        return parseResult(json: finalJson, rawString: rawJsonString)
    }
    
    private func consumeData(connection: NWConnection) async {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self = self else { return }
            if isComplete {
                connection.cancel()
                return
            }
            Task { await self.consumeData(connection: connection) }
        }
    }
    
    private func parseResult(json: [String: Any]?, rawString: String) -> RPerfResult {
        guard let json = json else {
            return RPerfResult(success: false, error: "No result received")
        }
        
        let success = json["success"] as? Bool ?? true
        var summary = RPerfSummary()
        
        if let summaryDict = json["summary"] as? [String: Any] {
            summary.duration = summaryDict["duration_send"] as? Double ?? summaryDict["duration_receive"] as? Double ?? 0
            summary.bytes_sent = summaryDict["bytes_sent"] as? UInt64 ?? 0
            summary.bytes_received = summaryDict["bytes_received"] as? UInt64 ?? 0
            
            if summary.duration > 0 {
                let bytes = max(summary.bytes_received, summary.bytes_sent)
                summary.bits_per_second = (Double(bytes) * 8.0) / summary.duration
            }
            
            if testProtocol == .udp {
                summary.packets_sent = summaryDict["packets_sent"] as? UInt64 ?? 0
                summary.packets_received = summaryDict["packets_received"] as? UInt64 ?? 0
                summary.packets_lost = summary.packets_sent >= summary.packets_received ? summary.packets_sent - summary.packets_received : 0
                if summary.packets_sent > 0 {
                    summary.loss_percent = (Double(summary.packets_lost) / Double(summary.packets_sent)) * 100.0
                }
                if let jitter = summaryDict["jitter_average"] as? Double {
                    summary.jitter_ms = jitter * 1000.0
                }
            }
        }
        
        return RPerfResult(success: success, results_json: rawString, summary: summary)
    }
}

@available(macOS 11.0, iOS 14.0, *)
public class AsyncNWConnection: @unchecked Sendable {
    public let connection: NWConnection
    private var buffer = Data()
    
    public init(connection: NWConnection) {
        self.connection = connection
    }
    
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = AtomicBool()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed.exchange(with: true) {
                        continuation.resume()
                    }
                case .failed(let err):
                    if !resumed.exchange(with: true) {
                        continuation.resume(throwing: err)
                    }
                case .cancelled:
                    if !resumed.exchange(with: true) {
                        continuation.resume(throwing: CancellationError())
                    }
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }
    
    public func send(json: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        var payload = data
        payload.append(contentsOf: [UInt8(ascii: "\n")])
        try await send(data: payload)
    }
    
    public func send(data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    public func receiveJSON() async throws -> [String: Any] {
        return try await receiveJSONAndString().0
    }
    
    public func receiveJSONAndString() async throws -> ([String: Any], String) {
        while true {
            if let range = buffer.range(of: Data([UInt8(ascii: "\n")])) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                if let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    return (json, String(data: lineData, encoding: .utf8) ?? "")
                }
                continue
            }
            
            let data = try await receiveChunk()
            buffer.append(data)
        }
    }
    
    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: URLError(.networkConnectionLost))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
    
    public func cancel() {
        connection.cancel()
    }
}