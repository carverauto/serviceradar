import SwiftUI
import RealityKit
import ARKit
import Combine
import CoreLocation

/// Integrates RealityKit and ARKit for 6DoF tracking, environment understanding,
/// and rendering the high-performance UI over the live camera feed with real Wi-Fi APIs.
public struct ARRealityView: UIViewRepresentable {
    
    @ObservedObject public var scanner: RealWiFiScanner
    
    public init(scanner: RealWiFiScanner) {
        self.scanner = scanner
    }
    
    public func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        
        // Enabling Scene Reconstruction (LiDAR mesh generation for RealityKit physics/occlusion)
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
            arView.environment.sceneUnderstanding.options.insert(.physics)
        }
        
        arView.session.run(config)
        
        // Post-processing for "Surveyor Nocturne" aesthetic
        arView.renderOptions.insert(.disableGroundingShadows)
        arView.renderOptions.insert(.disableHDR) 
        
        // Root Anchor for relative AR coordinate space
        let rootAnchor = AnchorEntity(world: SIMD3<Float>(0,0,0))
        rootAnchor.name = "SurveyRoot"
        arView.scene.addAnchor(rootAnchor)
        
        return arView
    }
    
    public func updateUIView(_ uiView: ARView, context: Context) {
        guard let rootAnchor = uiView.scene.findEntity(named: "SurveyRoot") as? AnchorEntity else { return }
        
        // Extract the device's current position to determine relative RF source estimations
        var cameraPosition = SIMD3<Float>(0, 0, 0)
        if let currentFrame = uiView.session.currentFrame {
            cameraPosition = SIMD3<Float>(
                currentFrame.camera.transform.columns.3.x,
                currentFrame.camera.transform.columns.3.y,
                currentFrame.camera.transform.columns.3.z
            )
        }
        
        var currentEntities = Set(rootAnchor.children.map { $0.name })
        
        let samples = Array(scanner.accessPoints.values)
        
        for var sample in samples {
            let entityName = "AP_\(sample.bssid)"
            currentEntities.remove(entityName)
            
            // Log-distance path loss estimate using exact RealityKit float space
            let txPower = sample.frequency > 4000 ? -45.0 : -35.0
            let n = 3.0
            let estimatedDistance = Float(pow(10.0, (txPower - sample.rssi) / (10.0 * n)))
            
            // Derive spatial location by projecting outward from camera into Z space
            // In a full implementation, we'd triangulate, here we push out via the distance constraint
            let zOffset = min(estimatedDistance, 10.0) // Clamp to max 10 meters for viewability
            let targetPos = SIMD3<Float>(cameraPosition.x, cameraPosition.y, cameraPosition.z - zOffset)
            
            if let existing = rootAnchor.findEntity(named: entityName) {
                // Smooth interpolation for existing entities based on actual RSSI swings
                existing.move(to: Transform(scale: existing.scale, rotation: existing.orientation, translation: targetPos),
                              relativeTo: rootAnchor,
                              duration: 1.0, timingFunction: .easeInOut)
                
            } else {
                // Initialize new ModelEntity for newly detected MAC/BSSID
                let sphere = MeshResource.generateSphere(radius: 0.15)
                
                var material = SimpleMaterial()
                material.color = .init(tint: sample.frequency > 4000 ? .cyan : .orange)
                
                let apEntity = ModelEntity(mesh: sphere, materials: [material])
                apEntity.name = entityName
                apEntity.position = targetPos
                
                // Scale core size directly based on network signal strength
                let scale = max(0.1, min(1.0, Float(sample.rssi + 90) / 60.0))
                apEntity.scale = SIMD3<Float>(repeating: scale)
                
                rootAnchor.addChild(apEntity)
            }
        }
        
        // Culling entities that drop out of visible range
        for staleName in currentEntities {
            if let staleEntity = rootAnchor.findEntity(named: staleName) {
                staleEntity.removeFromParent()
            }
        }
    }
}
