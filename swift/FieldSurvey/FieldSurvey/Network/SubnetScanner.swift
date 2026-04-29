#if os(iOS)
import Foundation
import Network
import Combine
import os.log

/// Performs active subnet sweeping and Bonjour/mDNS discovery to associate
/// Associates Wi-Fi survey observations with logical IP addresses and hostnames on the local network.
@MainActor
public class SubnetScanner: ObservableObject {
    public static let shared = SubnetScanner()
    
    // Maps discovered hostnames to their resolved IP Address and Name
    @Published public var discoveredDevices: [String: (ip: String, hostname: String)] = [:]
    
    private let logger = Logger(subsystem: "com.serviceradar.fieldsurvey", category: "SubnetScanner")
    private var browsers: [NWBrowser] = []
    private var posixTask: Task<Void, Never>?
    private let browserQueue = DispatchQueue(label: "com.serviceradar.fieldsurvey.subnet.browser", qos: .utility)
    private let resolveQueue = DispatchQueue(label: "com.serviceradar.fieldsurvey.subnet.resolve", qos: .utility, attributes: .concurrent)
    private var isScanning = false
    private var localNetworkAuthorizationDenied = false
    private var didReportAuthorizationFailure = false
    private var authorizationBlockUntil: Date?
    private var lastResolveAttemptAt: [String: Date] = [:]
    private var activeResolveConnections: [String: NWConnection] = [:]
    private let resolveRetryWindow: TimeInterval = 25.0
    private let resolveTimeout: TimeInterval = 0.9
    private let maxConcurrentResolves = 6
    
    public init() {}
    
    public func startScanning() {
        guard !isScanning else { return }
        if let blockedUntil = authorizationBlockUntil, blockedUntil > Date() {
            return
        }
        if localNetworkAuthorizationDenied {
            localNetworkAuthorizationDenied = false
        }
        isScanning = true

        // Aggressive Bonjour/mDNS sweep for standard AP and IoT services
        let services = [
            "_http._tcp",
            "_https._tcp",
            "_ssh._tcp",
            "_ubiquiti._tcp",
            "_cisco-wlc._tcp",
            "_meraki._tcp"
        ]
        
        for service in services {
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: service, domain: "local."), using: parameters)

            browser.stateUpdateHandler = { [weak self] state in
                guard let self else { return }

                switch state {
                case .waiting(let error), .failed(let error):
                    if Self.isAuthorizationError(error) {
                        Task { @MainActor [weak self] in
                            self?.handleAuthorizationFailure(error: error)
                        }
                    }
                default:
                    break
                }
            }
            
            browser.browseResultsChangedHandler = { [weak self] results, changes in
                for result in results {
                    if case NWEndpoint.service(let name, let type, _, _) = result.endpoint {
                        // Skip very noisy media discovery classes; they generate many failing connection probes
                        // and degrade AR tracking stability.
                        if type == "_googlecast._tcp" || type == "_airplay._tcp" || type == "_raop._tcp" {
                            continue
                        }
                        self?.resolve(endpoint: result.endpoint, name: name)
                    }
                }
            }
            
            browser.start(queue: browserQueue)
            browsers.append(browser)
        }
        logger.info("Started mDNS Subnet Sweeping across \(services.count) services.")
        
        posixTask = Task.detached(priority: .background) { [weak self] in
            self?.startPosixBroadcast()
        }
    }
    
    public func stopScanning() {
        isScanning = false
        for browser in browsers {
            browser.cancel()
        }
        browsers.removeAll()
        for connection in activeResolveConnections.values {
            connection.cancel()
        }
        activeResolveConnections.removeAll()
        lastResolveAttemptAt.removeAll()
        posixTask?.cancel()
        posixTask = nil
        logger.info("Stopped Subnet Sweeping.")
    }

    nonisolated private static func isAuthorizationError(_ error: NWError) -> Bool {
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("NoAuth") {
            return true
        }

        if case .posix(let code) = error {
            return code == .EPERM || code == .EACCES
        }
        return false
    }

    private func handleAuthorizationFailure(error: NWError) {
        localNetworkAuthorizationDenied = true
        authorizationBlockUntil = Date().addingTimeInterval(30)
        if !didReportAuthorizationFailure {
            didReportAuthorizationFailure = true
            logger.error("Local network browse authorization failed (\(String(describing: error))). Disable subnet sweep until permission is granted.")
        }
        stopScanning()
    }
    
    nonisolated private func startPosixBroadcast() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        
        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout.size(ofValue: broadcast)))
        
        var timeout = timeval(tv_sec: 0, tv_usec: 450_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        
        let ubiPayload = Data([0x01, 0x00, 0x00, 0x00])
        let nbnsPayload = Data([
            0x8a, 0x00, 0x01, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x20, 0x43, 0x4b, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x00, 0x00, 0x21, 
            0x00, 0x01
        ])
        let snmpPayload = Data([
            0x30, 0x29, 0x02, 0x01, 0x00, 0x04, 0x06, 0x70, 0x75, 0x62, 0x6c, 0x69, 
            0x63, 0xa0, 0x1c, 0x02, 0x04, 0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x00, 
            0x02, 0x01, 0x00, 0x30, 0x0e, 0x30, 0x0c, 0x06, 0x08, 0x2b, 0x06, 0x01, 
            0x02, 0x01, 0x01, 0x05, 0x00, 0x05, 0x00
        ])
        
        func sendPacket(_ data: Data, port: UInt16) {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("255.255.255.255")
            data.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        sendto(fd, buf.baseAddress, buf.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        
        while !Task.isCancelled {
            sendPacket(ubiPayload, port: 10001)
            sendPacket(nbnsPayload, port: 137)
            sendPacket(snmpPayload, port: 161)
            
            var buffer = [UInt8](repeating: 0, count: 2048)
            var srcAddr = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            
            while !Task.isCancelled {
                let bytesRead = withUnsafeMutablePointer(to: &srcAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        recvfrom(fd, &buffer, buffer.count, 0, saPtr, &srcLen)
                    }
                }
                if bytesRead <= 0 { break } // Timeout, loop and send broadcast again
                
                let ipStr = String(cString: inet_ntoa(srcAddr.sin_addr))
                let port = UInt16(bigEndian: srcAddr.sin_port)
                
                // Copy values before capturing into MainActor Task to prevent data races
                let str = String(bytes: buffer[0..<Int(bytesRead)], encoding: .ascii) ?? ""
                let cleanStr = str.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
                
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    var host = "UDP-Device"
                    if port == 10001 { host = "Ubiquiti-Device" }
                    else if port == 137 { host = "NetBIOS-Device" }
                    else if port == 161 { host = "SNMP-Device" }
                    
                    if cleanStr.count > 3 {
                        host = "\(host) (\(cleanStr.prefix(15)))"
                    }
                    
                    self.discoveredDevices[ipStr] = (ip: ipStr, hostname: host)
                }
            }

            if Task.isCancelled { break }
            usleep(2_500_000)
        }
        close(fd)
    }
    
    nonisolated private func resolve(endpoint: NWEndpoint, name: String) {
        Task { @MainActor [weak self] in
            guard let self = self, self.isScanning else { return }

            let key = self.endpointKey(endpoint: endpoint, name: name)
            let now = Date()
            if let lastAttempt = self.lastResolveAttemptAt[key], now.timeIntervalSince(lastAttempt) < self.resolveRetryWindow {
                return
            }
            guard self.activeResolveConnections.count < self.maxConcurrentResolves else { return }

            self.lastResolveAttemptAt[key] = now

            // We open a lightweight TCP connection only long enough for iOS to resolve the concrete host.
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let connection = NWConnection(to: endpoint, using: params)
            self.activeResolveConnections[key] = connection

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, _) = innerEndpoint {

                        var ipAddress = ""
                        switch host {
                        case .ipv4(let ipv4): ipAddress = "\(ipv4)"
                        case .ipv6(let ipv6): ipAddress = "\(ipv6)"
                        default: break
                        }

                        let normalizedIP = ipAddress.components(separatedBy: "%").first ?? ipAddress
                        if !normalizedIP.isEmpty {
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.discoveredDevices[normalizedIP] = (ip: normalizedIP, hostname: name)
                                self.logger.debug("Subnet Sweep resolved: \(name) at \(normalizedIP)")
                                self.finishResolve(key: key)
                            }
                        } else {
                            Task { @MainActor [weak self] in
                                self?.finishResolve(key: key)
                            }
                        }
                    } else {
                        Task { @MainActor [weak self] in
                            self?.finishResolve(key: key)
                        }
                    }
                case .failed(_), .cancelled:
                    Task { @MainActor [weak self] in
                        self?.finishResolve(key: key)
                    }
                default:
                    break
                }
            }

            connection.start(queue: resolveQueue)
            resolveQueue.asyncAfter(deadline: .now() + self.resolveTimeout) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let inflight = self.activeResolveConnections[key] {
                        inflight.cancel()
                        self.activeResolveConnections.removeValue(forKey: key)
                    }
                }
            }
        }
    }

    private func endpointKey(endpoint: NWEndpoint, name: String) -> String {
        if case let .service(serviceName, type, domain, interface) = endpoint {
            let iface = interface?.name ?? "-"
            return "\(serviceName)|\(type)|\(domain)|\(iface)"
        }
        return "endpoint|\(name)|\(String(describing: endpoint))"
    }

    private func finishResolve(key: String) {
        activeResolveConnections[key]?.cancel()
        activeResolveConnections.removeValue(forKey: key)
    }
}
#endif
