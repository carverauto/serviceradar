#if os(iOS)
import Foundation
import Combine
import CoreBluetooth

/// Manages Bluetooth Low Energy (BLE) scanning to capture the BLE environment 
/// for high-fidelity indoor positioning alongside Wi-Fi arrays.
@MainActor
public class BLEScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    @MainActor public static let shared = BLEScanner()
    
    @Published public var discoveredPeripherals: [UUID: (rssi: Double, name: String)] = [:]
    
    private var centralManager: CBCentralManager!
    private var scanningEnabled = false
    
    public override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    public func startScanning() {
        scanningEnabled = true
        guard centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }
    
    public func stopScanning(clearData: Bool = false) {
        scanningEnabled = false
        centralManager.stopScan()
        if clearData {
            discoveredPeripherals.removeAll()
        }
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled {
            startScanning()
        } else {
            stopScanning(clearData: true)
        }
    }
    
    public var currentBleVector: [Double] {
        // Sort by UUID string to maintain a deterministic vector for KNN fingerprinting
        return discoveredPeripherals.sorted { $0.key.uuidString < $1.key.uuidString }.map { $0.value.rssi }
    }
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if scanningEnabled {
                centralManager.scanForPeripherals(
                    withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                )
            }
        } else {
            stopScanning()
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let rssiValue = RSSI.doubleValue
        // Ignore wildly invalid RSSI values
        if rssiValue < 0 && rssiValue >= -100 {
            let deviceName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "BLE Beacon"
            self.discoveredPeripherals[peripheral.identifier] = (rssi: rssiValue, name: deviceName)
        }
    }
}
#endif
