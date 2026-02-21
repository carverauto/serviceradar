import SwiftUI
import SceneKit
import Combine
import Foundation

// MARK: - App Entry
@main
struct FieldSurveyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Models
struct WiFiAccessPoint: Identifiable, Hashable {
    let id: String // BSSID
    let ssid: String
    var rssi: Double
    let frequency: Int // MHz, e.g., 2412 or 5180
    var estimatedDistance: Double {
        // Log-distance path loss model
        let txPower = frequency > 4000 ? -45.0 : -35.0 // Approximate Tx Power at 1m
        let n = 3.0 // Path loss exponent (free space = 2, indoors = 3-4)
        return pow(10.0, (txPower - rssi) / (10.0 * n))
    }
    
    var is5GHz: Bool {
        frequency > 4000
    }
    
    // Position in 3D space
    var position: SCNVector3 = SCNVector3(
        Float.random(in: -5...5),
        Float.random(in: -2...2),
        Float.random(in: -5...5)
    )
    
    var uncertainty: Float = 1.0
}

// MARK: - Scanner (Mocked for iOS limitations)
class WiFiScanner: ObservableObject {
    @Published var accessPoints: [String: WiFiAccessPoint] = [:]
    private var timer: Timer?
    
    // In a real private iOS app or macOS app, we would use CoreWLAN or NEHotspotHelper here.
    // Due to public iOS API restrictions on aggressive Wi-Fi scanning, we mock the environment.
    
    let mockAPs = [
        ("Home_Network", "00:11:22:33:44:55", 5180),
        ("Home_Network_2G", "00:11:22:33:44:56", 2412),
        ("Guest_WiFi", "aa:bb:cc:dd:ee:ff", 2462),
        ("Neighbors_5G", "11:22:33:44:55:66", 5220),
        ("IoT_Hub", "22:33:44:55:66:77", 2437),
        ("Hidden_Network", "33:44:55:66:77:88", 5745)
    ]
    
    func startScanning() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.scan()
        }
        scan()
    }
    
    func stopScanning() {
        timer?.invalidate()
        timer = nil
    }
    
    private func scan() {
        var currentAPs = accessPoints
        
        for mock in mockAPs {
            let (ssid, bssid, freq) = mock
            // Simulate RSSI fluctuating
            let baseRssi = -60.0 + Double.random(in: -10...10)
            
            if var existing = currentAPs[bssid] {
                // Exponential moving average for smoothing
                existing.rssi = (existing.rssi * 0.7) + (baseRssi * 0.3)
                existing.uncertainty = max(0.1, existing.uncertainty * 0.9)
                currentAPs[bssid] = existing
            } else {
                let ap = WiFiAccessPoint(id: bssid, ssid: ssid, rssi: baseRssi, frequency: freq)
                currentAPs[bssid] = ap
            }
        }
        
        // Force-directed layout step to resolve positions
        resolvePositions(aps: &currentAPs)
        
        DispatchQueue.main.async {
            self.accessPoints = currentAPs
        }
    }
    
    private func resolvePositions(aps: inout [String: WiFiAccessPoint]) {
        let keys = Array(aps.keys)
        let learningRate: Float = 0.1
        
        for key in keys {
            guard var ap = aps[key] else { continue }
            
            let targetDistance = Float(ap.estimatedDistance)
            let currentDistance = simd_length(simd_float3(ap.position))
            
            // Push/pull along the vector from origin to match estimated distance
            if currentDistance > 0.001 {
                let direction = simd_normalize(simd_float3(ap.position))
                let error = currentDistance - targetDistance
                
                // Move towards target distance
                let adjustment = direction * (error * learningRate)
                ap.position.x -= adjustment.x
                ap.position.y -= adjustment.y
                ap.position.z -= adjustment.z
            }
            
            // Basic repulsion from other APs to spread them out
            for otherKey in keys where otherKey != key {
                guard let otherAp = aps[otherKey] else { continue }
                let diff = simd_float3(ap.position) - simd_float3(otherAp.position)
                let dist = simd_length(diff)
                if dist > 0.001 && dist < 2.0 {
                    let repulsion = simd_normalize(diff) * (0.05 / dist)
                    ap.position.x += repulsion.x
                    ap.position.y += repulsion.y
                    ap.position.z += repulsion.z
                }
            }
            
            aps[key] = ap
        }
    }
}

// MARK: - SceneKit View
struct SceneKitView: UIViewRepresentable {
    @ObservedObject var scanner: WiFiScanner
    
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .black
        view.showsStatistics = false
        
        // Setup Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.1
        cameraNode.position = SCNVector3(x: 0, y: 5, z: 15)
        cameraNode.look(at: SCNVector3Zero)
        view.scene?.rootNode.addChildNode(cameraNode)
        
        // User (Origin) Marker
        let originSphere = SCNSphere(radius: 0.2)
        originSphere.firstMaterial?.diffuse.contents = UIColor.white
        originSphere.firstMaterial?.emission.contents = UIColor.white
        let originNode = SCNNode(geometry: originSphere)
        view.scene?.rootNode.addChildNode(originNode)
        
        // Grid
        let grid = SCNFloor()
        grid.reflectivity = 0
        grid.firstMaterial?.diffuse.contents = UIColor(white: 0.1, alpha: 1.0)
        let gridNode = SCNNode(geometry: grid)
        gridNode.position = SCNVector3(0, -2, 0)
        view.scene?.rootNode.addChildNode(gridNode)
        
        return view
    }
    
    func updateUIView(_ scnView: SCNView, context: Context) {
        guard let scene = scnView.scene else { return }
        
        // Update nodes based on scanner data
        for ap in scanner.accessPoints.values {
            let nodeName = "AP_\(ap.id)"
            
            let apNode: SCNNode
            let haloNode: SCNNode
            let textNode: SCNNode
            
            if let existing = scene.rootNode.childNode(withName: nodeName, recursively: false) {
                apNode = existing
                haloNode = apNode.childNode(withName: "Halo", recursively: false)!
                textNode = apNode.childNode(withName: "Text", recursively: false)!
            } else {
                // Create Core Node
                apNode = SCNNode()
                apNode.name = nodeName
                
                let sphere = SCNSphere(radius: 0.15)
                let color = ap.is5GHz ? UIColor.systemBlue : UIColor.systemOrange
                sphere.firstMaterial?.diffuse.contents = color
                sphere.firstMaterial?.emission.contents = color
                apNode.geometry = sphere
                
                // Create Translucent Coverage Halo
                haloNode = SCNNode()
                haloNode.name = "Halo"
                let haloSphere = SCNSphere(radius: 1.0)
                haloSphere.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.2)
                haloSphere.firstMaterial?.isDoubleSided = true
                haloSphere.firstMaterial?.blendMode = .add
                haloNode.geometry = haloSphere
                apNode.addChildNode(haloNode)
                
                // Create Text Label
                textNode = SCNNode()
                textNode.name = "Text"
                let text = SCNText(string: "\(ap.ssid)
\(ap.is5GHz ? "5GHz" : "2.4GHz")", extrusionDepth: 0.0)
                text.font = UIFont.systemFont(ofSize: 0.5)
                text.firstMaterial?.diffuse.contents = UIColor.white
                textNode.geometry = text
                
                let centerBounds = (text.boundingBox.max.x - text.boundingBox.min.x) / 2.0
                textNode.pivot = SCNMatrix4MakeTranslation(centerBounds, 0, 0)
                textNode.scale = SCNVector3(0.5, 0.5, 0.5)
                textNode.position = SCNVector3(0, 0.3, 0)
                
                // Ensure text always faces camera
                let constraint = SCNBillboardConstraint()
                constraint.freeAxes = .all
                textNode.constraints = [constraint]
                
                apNode.addChildNode(textNode)
                scene.rootNode.addChildNode(apNode)
            }
            
            // Animate updates
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 1.0
            
            apNode.position = ap.position
            
            let normalizedRssi = max(0.1, min(1.0, (ap.rssi + 90) / 60))
            apNode.scale = SCNVector3(normalizedRssi, normalizedRssi, normalizedRssi)
            
            let coverageRadius = CGFloat(max(0.5, ap.estimatedDistance * 0.8))
            (haloNode.geometry as? SCNSphere)?.radius = coverageRadius
            
            let opacity = max(0.1, 1.0 - ap.uncertainty)
            haloNode.opacity = CGFloat(opacity)
            
            SCNTransaction.commit()
        }
    }
}

// MARK: - SwiftUI View
struct ContentView: View {
    @StateObject private var scanner = WiFiScanner()
    
    var body: some View {
        ZStack {
            SceneKitView(scanner: scanner)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                HStack {
                    VStack(alignment: .leading) {
                        Text("ServiceRadar FieldSurvey")
                            .font(.headline)
                            .foregroundColor(.green)
                        Text("Visible Nodes: \(scanner.accessPoints.count)")
                            .font(.subheadline)
                            .foregroundColor(.green.opacity(0.8))
                    }
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.green, lineWidth: 1)
                    )
                    
                    Spacer()
                }
                .padding(.top, 40)
                .padding(.horizontal)
                
                Spacer()
                
                // Controls
                HStack {
                    Button(action: {
                        scanner.startScanning()
                    }) {
                        Text("Start Scan")
                            .fontWeight(.bold)
                            .padding()
                            .background(Color.green.opacity(0.8))
                            .foregroundColor(.black)
                            .cornerRadius(10)
                    }
                    
                    Button(action: {
                        scanner.stopScanning()
                    }) {
                        Text("Stop Scan")
                            .fontWeight(.bold)
                            .padding()
                            .background(Color.red.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
}
