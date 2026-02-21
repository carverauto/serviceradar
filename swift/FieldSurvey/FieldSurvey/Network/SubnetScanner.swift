#if os(iOS)
import Foundation
import Network
import Combine
import os.log

/// Performs active subnet sweeping and Bonjour/mDNS discovery to associate
/// Wi-Fi and BLE signals with logical IP addresses and hostnames on the local network.
@MainActor
public class SubnetScanner: ObservableObject {
    public static let shared = SubnetScanner()
    
    // Maps discovered hostnames to their resolved IP Address and Name
    @Published public var discoveredDevices: [String: (ip: String, hostname: String)] = [:]
    
    private let logger = Logger(subsystem: "com.serviceradar.fieldsurvey", category: "SubnetScanner")
    private var browsers: [NWBrowser] = []
    private var posixTask: Task<Void, Never>?
    
    public init() {}
    
    public func startScanning() {
        // Aggressive Bonjour/mDNS sweep for standard AP and IoT services
        let services = [
            "_http._tcp", "_https._tcp", "_ssh._tcp", "_smb._tcp", 
            "_printer._tcp", "_ipp._tcp", "_googlecast._tcp", 
            "_airplay._tcp", "_raop._tcp", "_apple-mobdev2._tcp",
            "_ubiquiti._tcp", "_cisco-wlc._tcp", "_meraki._tcp"
        ]
        
        for service in services {
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: service, domain: "local."), using: parameters)
            
            browser.browseResultsChangedHandler = { [weak self] results, changes in
                for result in results {
                    if case NWEndpoint.service(let name, _, _, _) = result.endpoint {
                        self?.resolve(endpoint: result.endpoint, name: name)
                    }
                }
            }
            
            browser.start(queue: .main)
            browsers.append(browser)
        }
        logger.info("Started mDNS Subnet Sweeping across \(services.count) services.")
        
        posixTask = Task.detached(priority: .background) { [weak self] in
            self?.startPosixBroadcast()
        }
    }
    
    public func stopScanning() {
        for browser in browsers {
            browser.cancel()
        }
        browsers.removeAll()
        posixTask?.cancel()
        posixTask = nil
        logger.info("Stopped Subnet Sweeping.")
    }
    
    nonisolated private func startPosixBroadcast() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        
        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout.size(ofValue: broadcast)))
        
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
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
        }
        close(fd)
    }
    
    nonisolated private func resolve(endpoint: NWEndpoint, name: String) {
        // We open a dummy TCP connection just long enough for iOS to resolve the IP address
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
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
                    
                    if !ipAddress.isEmpty {
                        Task { @MainActor in
                            self?.discoveredDevices[name] = (ip: ipAddress, hostname: name)
                            self?.logger.debug("Subnet Sweep resolved: \(name) at \(ipAddress)")
                        }
                    }
                }
                connection.cancel()
            case .failed(_), .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .background))
    }
}
#endif