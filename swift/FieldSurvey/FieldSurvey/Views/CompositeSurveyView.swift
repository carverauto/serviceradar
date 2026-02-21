#if os(iOS)
import SwiftUI
import RoomPlan
import SceneKit
import ARKit

@available(iOS 16.0, *)
public struct CompositeSurveyView: UIViewRepresentable {
    @ObservedObject public var roomScanner: RoomScanner
    @ObservedObject public var wifiScanner: RealWiFiScanner
    
    @Binding public var isMapView: Bool
    
    public init(roomScanner: RoomScanner, wifiScanner: RealWiFiScanner, isMapView: Binding<Bool>) {
        self.roomScanner = roomScanner
        self.wifiScanner = wifiScanner
        self._isMapView = isMapView
    }
    
    public func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .black
        
        let roomView = RoomCaptureView(frame: .zero)
        roomView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        roomScanner.startSession(in: roomView)
        container.addSubview(roomView)
        
        let scnView = SCNView(frame: .zero)
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.backgroundColor = .clear
        scnView.scene = SCNScene()
        scnView.autoenablesDefaultLighting = true
        
        // Add subtle reference grid for the dark space look
        let floor = SCNFloor()
        floor.firstMaterial?.diffuse.contents = UIColor.darkGray.withAlphaComponent(0.2)
        floor.firstMaterial?.writesToDepthBuffer = false
        floor.firstMaterial?.blendMode = .add
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -1.5, 0) // Approx floor level
        scnView.scene?.rootNode.addChildNode(floorNode)
        
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        
        // HDR and Bloom for glowing nodes
        cameraNode.camera?.wantsHDR = true
        cameraNode.camera?.wantsExposureAdaptation = true
        cameraNode.camera?.exposureOffset = -0.5
        cameraNode.camera?.bloomIntensity = 2.0
        cameraNode.camera?.bloomBlurRadius = 10.0
        cameraNode.camera?.bloomThreshold = 0.3
        
        scnView.scene?.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
        
        let mapCameraNode = SCNNode()
        mapCameraNode.camera = SCNCamera()
        mapCameraNode.camera?.wantsHDR = true
        mapCameraNode.camera?.wantsExposureAdaptation = true
        mapCameraNode.camera?.exposureOffset = -0.5
        mapCameraNode.camera?.bloomIntensity = 2.0
        mapCameraNode.camera?.bloomBlurRadius = 10.0
        mapCameraNode.camera?.bloomThreshold = 0.3
        mapCameraNode.position = SCNVector3(0, 15, 0)
        mapCameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scnView.scene?.rootNode.addChildNode(mapCameraNode)
        
        container.addSubview(scnView)
        
        context.coordinator.container = container
        context.coordinator.roomView = roomView
        context.coordinator.scnView = scnView
        context.coordinator.cameraNode = cameraNode
        context.coordinator.mapCameraNode = mapCameraNode
        context.coordinator.startDisplayLink()
        
        return container
    }
    
    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.wifiScanner = wifiScanner
        context.coordinator.isMapView = isMapView
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
        var isMapView: Bool = false
        
        weak var container: UIView?
        weak var roomView: RoomCaptureView?
        weak var scnView: SCNView?
        var cameraNode: SCNNode?
        var mapCameraNode: SCNNode?
        
        private var displayLink: CADisplayLink?
        private var apNodes: [String: SCNNode] = [:]
        private var roomNodes: [UUID: SCNNode] = [:]
        
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
            guard let roomView = roomView, let scnView = scnView, let cameraNode = cameraNode, let mapCameraNode = mapCameraNode else { return }
            
            if isMapView {
                roomView.isHidden = true
                scnView.allowsCameraControl = true
                
                if scnView.pointOfView != mapCameraNode {
                    scnView.pointOfView = mapCameraNode
                }
            } else {
                roomView.isHidden = false
                scnView.allowsCameraControl = false
                
                if scnView.pointOfView != cameraNode {
                    scnView.pointOfView = cameraNode
                }
                
                if let frame = roomView.captureSession.arSession.currentFrame {
                    cameraNode.simdTransform = frame.camera.transform
                    cameraNode.camera?.projectionTransform = SCNMatrix4(frame.camera.projectionMatrix)
                }
            }
        }
        
        func updateRoomNodes() {
            guard let scene = scnView?.scene, let room = parent.roomScanner.currentRoom else { return }
            
            var currentKeys = Set(roomNodes.keys)
            
            func updateNode(id: UUID, transform: simd_float4x4, dimensions: simd_float3, color: UIColor, opacity: CGFloat, isWireframe: Bool = false) {
                currentKeys.remove(id)
                if let existing = roomNodes[id] {
                    existing.simdTransform = transform
                } else {
                    let box = SCNBox(width: CGFloat(dimensions.x), height: CGFloat(dimensions.y), length: CGFloat(dimensions.z), chamferRadius: 0.01)
                    box.firstMaterial?.diffuse.contents = color
                    box.firstMaterial?.emission.contents = color
                    box.firstMaterial?.emission.intensity = 1.0
                    box.firstMaterial?.transparency = opacity
                    box.firstMaterial?.writesToDepthBuffer = true
                    box.firstMaterial?.blendMode = .add
                    box.firstMaterial?.fillMode = isWireframe ? .lines : .fill
                    let node = SCNNode(geometry: box)
                    node.simdTransform = transform
                    scene.rootNode.addChildNode(node)
                    roomNodes[id] = node
                }
            }
            
            // "Matrix" neon green cyber-physical vibes
            let neonGreen = UIColor(red: 0.1, green: 0.9, blue: 0.2, alpha: 1.0)
            let dimGreen = UIColor(red: 0.0, green: 0.4, blue: 0.1, alpha: 1.0)
            
            for wall in room.walls { updateNode(id: wall.identifier, transform: wall.transform, dimensions: wall.dimensions, color: neonGreen, opacity: 0.15, isWireframe: true) }
            for door in room.doors { updateNode(id: door.identifier, transform: door.transform, dimensions: door.dimensions, color: neonGreen, opacity: 0.25) }
            for window in room.windows { updateNode(id: window.identifier, transform: window.transform, dimensions: window.dimensions, color: neonGreen, opacity: 0.2, isWireframe: true) }
            for object in room.objects { updateNode(id: object.identifier, transform: object.transform, dimensions: object.dimensions, color: dimGreen, opacity: 0.2) }
            
            for stale in currentKeys {
                roomNodes[stale]?.removeFromParentNode()
                roomNodes.removeValue(forKey: stale)
            }
        }
        
        func createAPNode(sample: SurveySample) -> SCNNode {
            let container = SCNNode()
            container.name = "Container_\(sample.bssid)"
            
            let is5G = sample.frequency > 4000
            let color = is5G ? UIColor.cyan : UIColor.orange
            
            // Core
            let core = SCNSphere(radius: 0.1)
            core.firstMaterial?.diffuse.contents = color
            core.firstMaterial?.emission.contents = color
            core.firstMaterial?.emission.intensity = 1.5
            let coreNode = SCNNode(geometry: core)
            coreNode.name = "Core"
            container.addChildNode(coreNode)
            
            // Uncertainty/Coverage Sphere
            let coverage = SCNSphere(radius: 2.0)
            coverage.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.1)
            coverage.firstMaterial?.emission.contents = color.withAlphaComponent(0.05)
            coverage.firstMaterial?.isDoubleSided = true
            coverage.firstMaterial?.blendMode = .add
            coverage.firstMaterial?.writesToDepthBuffer = false
            let coverageNode = SCNNode(geometry: coverage)
            coverageNode.name = "Coverage"
            coverageNode.opacity = 0.3
            container.addChildNode(coverageNode)
            
            // Text Label
            let text = SCNText(string: sample.ssid.isEmpty ? sample.bssid : sample.ssid, extrusionDepth: 0.0)
            text.font = UIFont.systemFont(ofSize: 0.12, weight: .medium)
            text.firstMaterial?.diffuse.contents = UIColor.white
            text.firstMaterial?.emission.contents = UIColor.white
            text.firstMaterial?.emission.intensity = 1.0
            text.flatness = 0.0
            
            let textNode = SCNNode(geometry: text)
            let (min, max) = textNode.boundingBox
            textNode.pivot = SCNMatrix4MakeTranslation((max.x - min.x)/2, (max.y - min.y)/2, 0)
            textNode.scale = SCNVector3(1, 1, 1)
            textNode.position = SCNVector3(0, 0.3, 0)
            
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            textNode.constraints = [billboard]
            container.addChildNode(textNode)
            
            return container
        }
        
        func updateNodes() {
            guard let scnView = scnView, let scene = scnView.scene, let wifiScanner = wifiScanner else { return }
            guard let frame = roomView?.captureSession.arSession.currentFrame else { return }
            
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            let cameraForward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
            
            let samples = Array(wifiScanner.accessPoints.values)
            var currentKeys = Set(apNodes.keys)
            
            for sample in samples {
                let key = sample.bssid
                currentKeys.remove(key)
                
                // Calculate unconstrained distance from free-space path loss
                let txPower = sample.frequency > 4000 ? -45.0 : -35.0
                let n = 3.0
                let estimatedDistance = Float(pow(10.0, (txPower - sample.rssi) / (10.0 * n)))
                let zOffset = min(max(estimatedDistance, 0.5), 15.0)
                let newTargetPos = cameraPos + (cameraForward * zOffset)
                
                if let existingNode = apNodes[key] {
                    // Update core scale based on signal strength
                    let scale = max(0.2, min(1.5, Float(sample.rssi + 100) / 60.0))
                    
                    // Converge position (Exponential Moving Average)
                    let alpha: Float = 0.02 // Very slow convergence to smooth jitter
                    let currentPos = existingNode.simdPosition
                    let convergedPos = currentPos * (1.0 - alpha) + newTargetPos * alpha
                    
                    let moveAction = SCNAction.move(to: SCNVector3(convergedPos), duration: 0.5)
                    moveAction.timingMode = .easeOut
                    existingNode.runAction(moveAction)
                    
                    if let core = existingNode.childNode(withName: "Core", recursively: false) {
                        core.runAction(SCNAction.scale(to: CGFloat(scale), duration: 0.5))
                    }
                    if let coverage = existingNode.childNode(withName: "Coverage", recursively: false) {
                        // Uncertainty shrinks (radius decreases) and opacity increases over time
                        let currentScale = coverage.scale.x
                        let newScale = max(0.3, currentScale * 0.98)
                        coverage.runAction(SCNAction.scale(to: CGFloat(newScale), duration: 0.5))
                        
                        let currentOpacity = coverage.opacity
                        let newOpacity = min(1.0, currentOpacity + 0.01)
                        coverage.runAction(SCNAction.fadeOpacity(to: CGFloat(newOpacity), duration: 0.5))
                    }
                    
                    DispatchQueue.main.async {
                        self.wifiScanner?.apPositions[key] = convergedPos
                    }
                } else {
                    let node = createAPNode(sample: sample)
                    node.simdPosition = newTargetPos
                    scene.rootNode.addChildNode(node)
                    apNodes[key] = node
                    
                    if let core = node.childNode(withName: "Core", recursively: false) {
                        let fadeOut = SCNAction.fadeOpacity(to: 0.6, duration: 1.0)
                        let fadeIn = SCNAction.fadeOpacity(to: 1.0, duration: 1.0)
                        core.runAction(SCNAction.repeatForever(SCNAction.sequence([fadeOut, fadeIn])))
                    }
                    
                    DispatchQueue.main.async {
                        self.wifiScanner?.apPositions[key] = newTargetPos
                    }
                }
            }
            
            for staleKey in currentKeys {
                if let node = apNodes.removeValue(forKey: staleKey) {
                    node.removeFromParentNode()
                }
            }
            
            updateRoomNodes()
        }
    }
}
#endif
