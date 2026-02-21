#if os(iOS)
import SwiftUI
import RoomPlan
import SceneKit
import ARKit

@available(iOS 16.0, *)
public struct CompositeSurveyView: UIViewRepresentable {
    @ObservedObject public var roomScanner: RoomScanner
    @ObservedObject public var wifiScanner: RealWiFiScanner
    
    public init(roomScanner: RoomScanner, wifiScanner: RealWiFiScanner) {
        self.roomScanner = roomScanner
        self.wifiScanner = wifiScanner
    }
    
    public func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        
        let roomView = RoomCaptureView(frame: .zero)
        roomView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        roomScanner.startSession(in: roomView)
        container.addSubview(roomView)
        
        let scnView = SCNView(frame: .zero)
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.backgroundColor = .clear
        scnView.scene = SCNScene()
        
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        scnView.scene?.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
        
        container.addSubview(scnView)
        
        context.coordinator.roomView = roomView
        context.coordinator.scnView = scnView
        context.coordinator.cameraNode = cameraNode
        context.coordinator.startDisplayLink()
        
        return container
    }
    
    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.wifiScanner = wifiScanner
        // We only need to trigger a check for new nodes when SwiftUI updates
        context.coordinator.updateNodes()
    }
    
    public static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
        coordinator.roomView?.captureSession.stop()
    }
    
    public func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }
    
    @MainActor
    public class Coordinator: NSObject {
        var parent: CompositeSurveyView
        var wifiScanner: RealWiFiScanner?
        
        weak var roomView: RoomCaptureView?
        weak var scnView: SCNView?
        var cameraNode: SCNNode?
        
        private var displayLink: CADisplayLink?
        private var apNodes: [String: SCNNode] = [:]
        
        init(_ parent: CompositeSurveyView) {
            self.parent = parent
        }
        
        func startDisplayLink() {
            displayLink = CADisplayLink(target: self, selector: #selector(updateCamera))
            displayLink?.add(to: .main, forMode: .common)
        }
        
        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }
        
        @objc func updateCamera() {
            guard let roomView = roomView, let cameraNode = cameraNode else { return }
            if let frame = roomView.captureSession.arSession.currentFrame {
                cameraNode.simdTransform = frame.camera.transform
                cameraNode.camera?.projectionTransform = SCNMatrix4(frame.camera.projectionMatrix)
            }
        }
        
        func updateNodes() {
            guard let scnView = scnView, let scene = scnView.scene, let wifiScanner = wifiScanner else { return }
            guard let frame = roomView?.captureSession.arSession.currentFrame else { return }
            
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            // Forward vector is negative Z column
            let cameraForward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
            
            let samples = Array(wifiScanner.accessPoints.values)
            var currentKeys = Set(apNodes.keys)
            
            for sample in samples {
                let key = sample.bssid
                currentKeys.remove(key)
                
                let scale = max(0.1, min(1.0, Float(sample.rssi + 90) / 60.0))
                
                if let existingNode = apNodes[key] {
                    // Smoothly animate scale based on RSSI changes, but DO NOT move the node around the world space.
                    let scaleAction = SCNAction.scale(to: CGFloat(scale), duration: 0.5)
                    existingNode.runAction(scaleAction)
                } else {
                    // Create new node at a fixed world location, projected forward from the camera's current pose
                    let txPower = sample.frequency > 4000 ? -45.0 : -35.0
                    let n = 3.0
                    let estimatedDistance = Float(pow(10.0, (txPower - sample.rssi) / (10.0 * n)))
                    let zOffset = min(estimatedDistance, 10.0)
                    
                    let targetPos = cameraPos + (cameraForward * zOffset)
                    
                    // Save to our central state so MapView can render it
                    DispatchQueue.main.async {
                        wifiScanner.apPositions[key] = targetPos
                    }
                    
                    let sphere = SCNSphere(radius: 0.15)
                    sphere.firstMaterial?.diffuse.contents = sample.frequency > 4000 ? UIColor.cyan : UIColor.orange
                    sphere.firstMaterial?.emission.contents = sample.frequency > 4000 ? UIColor.cyan : UIColor.orange
                    
                    let node = SCNNode(geometry: sphere)
                    node.simdPosition = targetPos
                    node.scale = SCNVector3(scale, scale, scale)
                    
                    // Add a subtle pulsing animation to make them look like active RF sources
                    let fadeOut = SCNAction.fadeOpacity(to: 0.5, duration: 1.0)
                    let fadeIn = SCNAction.fadeOpacity(to: 1.0, duration: 1.0)
                    node.runAction(SCNAction.repeatForever(SCNAction.sequence([fadeOut, fadeIn])))
                    
                    scene.rootNode.addChildNode(node)
                    apNodes[key] = node
                }
            }
            
            // Remove stale nodes
            for staleKey in currentKeys {
                if let node = apNodes.removeValue(forKey: staleKey) {
                    node.removeFromParentNode()
                }
            }
        }
    }
}
#endif
