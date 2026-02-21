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
                
                // Also update the projection matrix in case FOV/aspect ratio changes
                cameraNode.camera?.projectionTransform = SCNMatrix4(frame.camera.projectionMatrix)
            }
        }
        
        func updateNodes() {
            guard let scnView = scnView, let scene = scnView.scene, let wifiScanner = wifiScanner else { return }
            guard let frame = roomView?.captureSession.arSession.currentFrame else { return }
            
            let cameraPos = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            
            let samples = Array(wifiScanner.accessPoints.values)
            var currentKeys = Set(apNodes.keys)
            
            for sample in samples {
                let key = sample.bssid
                currentKeys.remove(key)
                
                let txPower = sample.frequency > 4000 ? -45.0 : -35.0
                let n = 3.0
                let estimatedDistance = Float(pow(10.0, (txPower - sample.rssi) / (10.0 * n)))
                let zOffset = min(estimatedDistance, 10.0)
                let targetPos = SIMD3<Float>(cameraPos.x, cameraPos.y, cameraPos.z - zOffset)
                
                if let existingNode = apNodes[key] {
                    // Update existing
                    let moveAction = SCNAction.move(to: SCNVector3(targetPos.x, targetPos.y, targetPos.z), duration: 1.0)
                    moveAction.timingMode = .easeInEaseOut
                    existingNode.runAction(moveAction)
                    
                    let scale = max(0.1, min(1.0, Float(sample.rssi + 90) / 60.0))
                    existingNode.scale = SCNVector3(scale, scale, scale)
                    
                } else {
                    // Create new
                    let sphere = SCNSphere(radius: 0.15)
                    sphere.firstMaterial?.diffuse.contents = sample.frequency > 4000 ? UIColor.cyan : UIColor.orange
                    sphere.firstMaterial?.emission.contents = sample.frequency > 4000 ? UIColor.cyan : UIColor.orange
                    
                    let node = SCNNode(geometry: sphere)
                    node.simdPosition = targetPos
                    
                    let scale = max(0.1, min(1.0, Float(sample.rssi + 90) / 60.0))
                    node.scale = SCNVector3(scale, scale, scale)
                    
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
