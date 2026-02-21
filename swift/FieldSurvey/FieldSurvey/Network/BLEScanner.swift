#if os(iOS)
import Foundation
import Combine
import CoreBluetooth

/// Manages Bluetooth Low Energy (BLE) scanning to capture the BLE environment 
/// for high-fidelity indoor positioning alongside Wi-Fi arrays.
@MainActor
public class BLEScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    @MainActor public static let shared = BLEScanner()
    
    @Published public var discoveredPeripherals: [UUID: Double] = [:]
    
    private var centralManager: CBCentralManager!
    
    public override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    public func startScanning() {
        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }
    
    public func stopScanning() {
        centralManager.stopScan()
    }
    
    public var currentBleVector: [Double] {
        // Sort by UUID string to maintain a deterministic vector for KNN fingerprinting
        return discoveredPeripherals.sorted { $0.key.uuidString < $1.key.uuidString }.map { $0.value }
    }
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanning()
        } else {
            stopScanning()
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let rssiValue = RSSI.doubleValue
        // Ignore wildly invalid RSSI values
        if rssiValue < 0 && rssiValue > -100 {
            self.discoveredPeripherals[peripheral.identifier] = rssiValue
        }
    }
}
#endif
