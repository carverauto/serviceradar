import Foundation
import Network
import Combine

/// Monitors the iOS device's active network connection (Wi-Fi, Cellular, Ethernet)
/// using NWPathMonitor to provide real-time connectivity status to the app UI.
@MainActor
public class NetworkMonitor: ObservableObject {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.serviceradar.fieldsurvey.networkmonitor")
    
    @Published public var isConnected: Bool = false
    @Published public var isWiFi: Bool = false
    @Published public var isCellular: Bool = false
    @Published public var isEthernet: Bool = false
    
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.isWiFi = path.usesInterfaceType(.wifi)
                self?.isCellular = path.usesInterfaceType(.cellular)
                self?.isEthernet = path.usesInterfaceType(.wiredEthernet)
            }
        }
        monitor.start(queue: queue)
    }
    
    deinit {
        monitor.cancel()
    }
}
