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
    }
    
    public func stopScanning() {
        for browser in browsers {
            browser.cancel()
        }
        browsers.removeAll()
        logger.info("Stopped Subnet Sweeping.")
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