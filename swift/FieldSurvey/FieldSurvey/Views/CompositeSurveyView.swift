#if os(iOS)
import SwiftUI
import RoomPlan
import SceneKit
import ARKit
import simd
import UIKit

@available(iOS 16.0, *)
public struct CompositeSurveyView: UIViewRepresentable {
    @ObservedObject public var roomScanner: RoomScanner
    @ObservedObject public var wifiScanner: RealWiFiScanner

    @Binding public var isMapView: Bool

    public init(
        roomScanner: RoomScanner,
        wifiScanner: RealWiFiScanner,
        isMapView: Binding<Bool>
    ) {
        self.roomScanner = roomScanner
        self.wifiScanner = wifiScanner
        self._isMapView = isMapView
    }

    public func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .black

        let roomView = RoomCaptureView(frame: container.bounds)
        roomView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        roomScanner.startSession(in: roomView)
        roomView.captureSession.arSession.delegate = context.coordinator
        container.addSubview(roomView)

        let scnView = SCNView(frame: container.bounds)
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.backgroundColor = .clear
        scnView.scene = SCNScene()
        scnView.autoenablesDefaultLighting = false
        scnView.preferredFramesPerSecond = 12
        scnView.antialiasingMode = .multisampling2X
        scnView.isJitteringEnabled = false
        scnView.rendersContinuously = false
        scnView.isPlaying = false
        scnView.isHidden = true

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 900
        ambientLight.color = UIColor(white: 0.92, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scnView.scene?.rootNode.addChildNode(ambientNode)

        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1200
        keyLight.castsShadow = false
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.eulerAngles = SCNVector3(-Float.pi / 3.2, Float.pi / 5.0, 0)
        scnView.scene?.rootNode.addChildNode(keyNode)

        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 500
        fillLight.color = UIColor(white: 0.75, alpha: 1.0)
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.eulerAngles = SCNVector3(-Float.pi / 4.0, -Float.pi / 2.0, 0)
        scnView.scene?.rootNode.addChildNode(fillNode)

        let ground = SCNPlane(width: 80, height: 80)
        ground.firstMaterial?.diffuse.contents = UIColor(white: 0.15, alpha: 0.2)
        ground.firstMaterial?.isDoubleSided = true
        ground.firstMaterial?.lightingModel = .physicallyBased
        let groundNode = SCNNode(geometry: ground)
        groundNode.eulerAngles = SCNVector3(-Float.pi / 2.0, 0, 0)
        groundNode.position = SCNVector3(0, -1.5, 0)
        scnView.scene?.rootNode.addChildNode(groundNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.wantsHDR = true
        cameraNode.camera?.wantsExposureAdaptation = true
        cameraNode.camera?.exposureOffset = -0.35
        cameraNode.camera?.bloomIntensity = 1.4
        cameraNode.camera?.bloomBlurRadius = 9.0
        cameraNode.camera?.bloomThreshold = 0.55
        scnView.scene?.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode

        let mapCameraNode = SCNNode()
        mapCameraNode.camera = SCNCamera()
        mapCameraNode.camera?.wantsHDR = true
        mapCameraNode.camera?.wantsExposureAdaptation = true
        mapCameraNode.camera?.exposureOffset = -0.15
        mapCameraNode.camera?.bloomIntensity = 0.8
        mapCameraNode.camera?.bloomBlurRadius = 4.0
        mapCameraNode.camera?.bloomThreshold = 0.75
        mapCameraNode.position = SCNVector3(0, 7, 7)
        scnView.scene?.rootNode.addChildNode(mapCameraNode)

        container.addSubview(scnView)

        context.coordinator.container = container
        context.coordinator.roomView = roomView
        context.coordinator.scnView = scnView
        context.coordinator.cameraNode = cameraNode
        context.coordinator.mapCameraNode = mapCameraNode

        context.coordinator.setupBackgroundObservers()
        if isMapView {
            context.coordinator.startDisplayLink()
        } else {
            context.coordinator.startCaptureHealthTimer()
        }

        return container
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.wifiScanner = wifiScanner
        context.coordinator.isMapView = isMapView
        if isMapView {
            context.coordinator.stopCaptureHealthTimer()
            context.coordinator.startDisplayLink()
            context.coordinator.updateNodes()
        } else {
            context.coordinator.stopDisplayLink()
            context.coordinator.startCaptureHealthTimer()
            context.coordinator.clearSurveyOverlayNodes()
        }
    }

    public static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardownARPriorityMode()
        coordinator.removeBackgroundObservers()
        coordinator.stopDisplayLink()
        coordinator.stopCaptureHealthTimer()
        coordinator.roomView?.captureSession.stop()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    public class Coordinator: NSObject, @preconcurrency ARSessionDelegate {
        var parent: CompositeSurveyView
        var wifiScanner: RealWiFiScanner?
        var isMapView: Bool = false

        weak var container: UIView?
        weak var roomView: RoomCaptureView?
        weak var scnView: SCNView?

        var cameraNode: SCNNode?
        var mapCameraNode: SCNNode?

        private var displayLink: CADisplayLink?
        private var captureHealthTimer: Timer?
        private var apNodes: [String: SCNNode] = [:]
        private var roomNodes: [UUID: SCNNode] = [:]

        private var roomMeshNode: SCNNode?
        private var lastRoomMeshRefresh: CFTimeInterval = 0
        private var lastRoomMeshSignature: Int?
        private var lastNodeRenderTime: CFTimeInterval = 0
        private var lastLiveFrameProcessTime: TimeInterval = 0
        private let liveFrameProcessInterval: TimeInterval = 0.20

        private var previousMapState = false

        private var lastSessionRecoveryTime: CFTimeInterval = 0
        private var nilFrameStartTime: CFTimeInterval?
        private var needsSessionRecoveryOnForeground = false
        private var lastARFrameTimestamp: TimeInterval = 0
        private var staleTimestampStartTime: CFTimeInterval?
        private var trackingUnavailableStartTime: CFTimeInterval?
        private var enteredBackgroundAt: CFTimeInterval?
        private var lastSessionStartTime: CFTimeInterval = CACurrentMediaTime()
        private var isAppActive = true
        private var arPriorityLoadShedActive = false
        private var arPriorityStableSince: CFTimeInterval?
        private var lastARPriorityTransitionTime: CFTimeInterval = 0

        init(_ parent: CompositeSurveyView) {
            self.parent = parent
        }

        func setupBackgroundObservers() {
            NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        func removeBackgroundObservers() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func appWillResignActive() {
            isAppActive = false
            stopDisplayLink()
            stopCaptureHealthTimer()
            scnView?.isPlaying = false
            needsSessionRecoveryOnForeground = true
        }

        @objc func appDidEnterBackground() {
            isAppActive = false
            enteredBackgroundAt = CACurrentMediaTime()
            stopDisplayLink()
            stopCaptureHealthTimer()
            scnView?.isPlaying = false
            needsSessionRecoveryOnForeground = true
        }

        @objc func appWillEnterForeground() {
            isAppActive = false
        }

        @objc func appDidBecomeActive() {
            isAppActive = true
            if isMapView {
                startDisplayLink()
            } else {
                startCaptureHealthTimer()
            }
            scnView?.isPlaying = isMapView

            if needsSessionRecoveryOnForeground {
                needsSessionRecoveryOnForeground = false
                let now = CACurrentMediaTime()
                let idleDuration = enteredBackgroundAt.map { now - $0 } ?? 0
                enteredBackgroundAt = nil
                let reason = idleDuration > 3.0 ? "app-active-idle" : "app-active"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.recoverRoomCaptureSession(reason: reason)
                }
            }
        }

        func startDisplayLink() {
            guard displayLink == nil else { return }
            displayLink = CADisplayLink(target: self, selector: #selector(updateCamera))
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 6, maximum: 12, preferred: 10)
            displayLink?.add(to: .main, forMode: .common)
        }

        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        func startCaptureHealthTimer() {
            guard captureHealthTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0, target: self, selector: #selector(captureHealthTick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            captureHealthTimer = timer
        }

        func stopCaptureHealthTimer() {
            captureHealthTimer?.invalidate()
            captureHealthTimer = nil
        }

        @objc private func captureHealthTick() {
            guard !isMapView, isAppActive else { return }
            guard let frame = roomView?.captureSession.arSession.currentFrame else {
                maybeRecoverMissingARFrames()
                return
            }
            monitorFrameLiveness(frame)
        }

        @objc func handleSceneTap(_ recognizer: UITapGestureRecognizer) {
            return
        }

        @objc func updateCamera() {
            guard isMapView else {
                stopDisplayLink()
                return
            }
            guard let roomView = roomView, let scnView = scnView, let cameraNode = cameraNode, let mapCameraNode = mapCameraNode else { return }

            maybeUpdateARPriorityMode(isTrackingHealthy: true, now: CACurrentMediaTime())
            roomView.isHidden = true
            scnView.isHidden = false
            scnView.isPlaying = true
            scnView.allowsCameraControl = true

            if scnView.pointOfView != mapCameraNode {
                scnView.pointOfView = mapCameraNode
            }

            if !previousMapState {
                let target = SCNVector3(
                    cameraNode.position.x,
                    max(cameraNode.position.y + 7.0, 4.0),
                    cameraNode.position.z + 7.0
                )
                mapCameraNode.position = target
                mapCameraNode.look(at: cameraNode.position)
            }

            refreshRoomMeshIfNeeded(force: !previousMapState)

            let hasMesh = roomMeshNode != nil
            for node in roomNodes.values {
                node.isHidden = hasMesh
            }
            roomMeshNode?.isHidden = false
            previousMapState = isMapView
        }

        public func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard !isMapView else { return }
            guard isAppActive else { return }
            guard frame.timestamp - lastLiveFrameProcessTime >= liveFrameProcessInterval else { return }
            lastLiveFrameProcessTime = frame.timestamp
            processLiveCaptureFrame(frame)
        }

        private func processLiveCaptureFrame(_ frame: ARFrame) {
            nilFrameStartTime = nil
            monitorFrameLiveness(frame)

            cameraNode?.simdTransform = frame.camera.transform
            cameraNode?.camera?.projectionTransform = SCNMatrix4(frame.camera.projectionMatrix)

            let cameraPos = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            wifiScanner?.updateDevicePose(
                position: cameraPos,
                orientation: simd_quatf(frame.camera.transform),
                monotonicTimestampSeconds: frame.timestamp,
                trackingQuality: trackingQualityLabel(frame.camera.trackingState)
            )
            wifiScanner?.queueHeatmapCaptureFromCurrentPose(position: cameraPos)

            roomView?.isHidden = false
            scnView?.isHidden = true
            scnView?.isPlaying = false
            scnView?.allowsCameraControl = false
            roomMeshNode?.isHidden = true
            for node in roomNodes.values {
                node.isHidden = true
            }
            previousMapState = false
        }

        private func trackingQualityLabel(_ state: ARCamera.TrackingState) -> String {
            switch state {
            case .normal:
                return "normal"
            case .notAvailable:
                return "not_available"
            case .limited(let reason):
                switch reason {
                case .initializing:
                    return "limited_initializing"
                case .excessiveMotion:
                    return "limited_excessive_motion"
                case .insufficientFeatures:
                    return "limited_insufficient_features"
                case .relocalizing:
                    return "limited_relocalizing"
                @unknown default:
                    return "limited_unknown"
                }
            }
        }

        private func maybeRecoverMissingARFrames() {
            let now = CACurrentMediaTime()
            guard isAppActive else { return }
            maybeUpdateARPriorityMode(isTrackingHealthy: false, now: now)
            guard now - lastSessionStartTime > 3.2 else { return }
            if nilFrameStartTime == nil {
                nilFrameStartTime = now
                return
            }

            guard let nilStart = nilFrameStartTime else { return }
            guard now - nilStart > 1.6 else { return }
            recoverRoomCaptureSession(reason: "frame-timeout")
            nilFrameStartTime = now
        }

        private func monitorFrameLiveness(_ frame: ARFrame) {
            let now = CACurrentMediaTime()
            guard isAppActive else { return }
            guard now - lastSessionStartTime > 3.0 else { return }
            let timestamp = frame.timestamp
            var trackingHealthy = true

            if timestamp <= lastARFrameTimestamp + 0.0001 {
                trackingHealthy = false
                if staleTimestampStartTime == nil {
                    staleTimestampStartTime = now
                } else if let staleStart = staleTimestampStartTime, now - staleStart > 1.4 {
                    recoverRoomCaptureSession(reason: "stale-frame")
                    staleTimestampStartTime = now
                }
            } else {
                lastARFrameTimestamp = timestamp
                staleTimestampStartTime = nil
            }

            switch frame.camera.trackingState {
            case .notAvailable:
                trackingHealthy = false
                if trackingUnavailableStartTime == nil {
                    trackingUnavailableStartTime = now
                } else if let start = trackingUnavailableStartTime, now - start > 1.1 {
                    recoverRoomCaptureSession(reason: "tracking-unavailable")
                    trackingUnavailableStartTime = now
                }
            case .limited(let reason):
                trackingHealthy = false
                switch reason {
                case .relocalizing:
                    if trackingUnavailableStartTime == nil {
                        trackingUnavailableStartTime = now
                    } else if let start = trackingUnavailableStartTime, now - start > 4.2 {
                        recoverRoomCaptureSession(reason: "tracking-limited-relocalizing")
                        trackingUnavailableStartTime = now
                    }
                case .initializing:
                    if trackingUnavailableStartTime == nil {
                        trackingUnavailableStartTime = now
                    } else if let start = trackingUnavailableStartTime, now - start > 6.0 {
                        recoverRoomCaptureSession(reason: "tracking-limited-initializing")
                        trackingUnavailableStartTime = now
                    }
                case .insufficientFeatures, .excessiveMotion:
                    // Holding the phone still or moving too fast is often transient; restarting here causes churn.
                    trackingUnavailableStartTime = nil
                @unknown default:
                    trackingUnavailableStartTime = nil
                }
            case .normal:
                trackingUnavailableStartTime = nil
            }

            maybeUpdateARPriorityMode(isTrackingHealthy: trackingHealthy, now: now)
        }

        private func maybeUpdateARPriorityMode(isTrackingHealthy: Bool, now: CFTimeInterval) {
            guard SettingsManager.shared.arPriorityModeEnabled else {
                if arPriorityLoadShedActive {
                    setARPriorityLoadShed(active: false, reason: "mode-disabled")
                }
                arPriorityStableSince = nil
                return
            }

            guard SettingsManager.shared.rfScanningEnabled else {
                if arPriorityLoadShedActive {
                    setARPriorityLoadShed(active: false, reason: "rf-disabled")
                }
                arPriorityStableSince = nil
                return
            }

            guard !isMapView else {
                if arPriorityLoadShedActive {
                    setARPriorityLoadShed(active: false, reason: "map-view")
                }
                arPriorityStableSince = nil
                return
            }

            if !isTrackingHealthy {
                arPriorityStableSince = nil
                if !arPriorityLoadShedActive && now - lastARPriorityTransitionTime > 0.9 {
                    setARPriorityLoadShed(active: true, reason: "tracking-degraded")
                }
                return
            }

            guard arPriorityLoadShedActive else { return }
            if arPriorityStableSince == nil {
                arPriorityStableSince = now
                return
            }

            if let stableSince = arPriorityStableSince, now - stableSince > 2.8, now - lastARPriorityTransitionTime > 0.9 {
                setARPriorityLoadShed(active: false, reason: "tracking-recovered")
            }
        }

        private func setARPriorityLoadShed(active: Bool, reason: String) {
            guard arPriorityLoadShedActive != active else { return }
            arPriorityLoadShedActive = active
            lastARPriorityTransitionTime = CACurrentMediaTime()
            SettingsManager.shared.setARPriorityLoadShedActive(active)

            if active {
                wifiScanner?.stopScanning(clearData: false)
                SubnetScanner.shared.stopScanning()
            } else {
                guard SettingsManager.shared.rfScanningEnabled else { return }
                wifiScanner?.startScanning()
                SubnetScanner.shared.startScanning()
            }

            print("FieldSurvey AR Priority \(active ? "ON" : "OFF"): \(reason)")
        }

        func teardownARPriorityMode() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if arPriorityLoadShedActive {
                    setARPriorityLoadShed(active: false, reason: "view-dismantle")
                } else {
                    SettingsManager.shared.setARPriorityLoadShedActive(false)
                }
            }
        }

        private func recoverRoomCaptureSession(reason: String) {
            let now = CACurrentMediaTime()
            guard isAppActive else {
                needsSessionRecoveryOnForeground = true
                return
            }
            guard now - lastSessionRecoveryTime > 5.0 else { return }
            guard !isMapView else {
                needsSessionRecoveryOnForeground = true
                return
            }
            lastSessionRecoveryTime = now
            resetFrameHealthTracking()

            if reason.hasPrefix("app-active") || reason == "session-interruption-ended" || reason == "session-failure" {
                if replaceRoomCaptureView() {
                    print("FieldSurvey AR recovery triggered with view rebuild: \(reason)")
                    return
                }
            }

            guard let roomView else {
                _ = replaceRoomCaptureView()
                print("FieldSurvey AR recovery triggered without existing room view: \(reason)")
                return
            }

            roomView.captureSession.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self, weak roomView] in
                guard let self, let roomView else { return }
                let configuration = RoomCaptureSession.Configuration()
                roomView.captureSession.run(configuration: configuration)
                roomView.captureSession.arSession.delegate = self
                self.lastSessionStartTime = CACurrentMediaTime()
            }
            print("FieldSurvey AR recovery triggered: \(reason)")
        }

        private func resetFrameHealthTracking() {
            nilFrameStartTime = nil
            staleTimestampStartTime = nil
            trackingUnavailableStartTime = nil
            lastARFrameTimestamp = 0
        }

        @discardableResult
        private func replaceRoomCaptureView() -> Bool {
            guard let container else { return false }

            let newRoomView = RoomCaptureView(frame: container.bounds)
            newRoomView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            newRoomView.isHidden = isMapView

            roomView?.captureSession.stop()
            roomView?.removeFromSuperview()
            container.insertSubview(newRoomView, at: 0)
            roomView = newRoomView

            parent.roomScanner.startSession(in: newRoomView)
            newRoomView.captureSession.arSession.delegate = self
            lastSessionStartTime = CACurrentMediaTime()
            return true
        }

        public func sessionWasInterrupted(_ session: ARSession) {
            needsSessionRecoveryOnForeground = true
        }

        public func sessionInterruptionEnded(_ session: ARSession) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.recoverRoomCaptureSession(reason: "session-interruption-ended")
            }
        }

        public func session(_ session: ARSession, didFailWithError error: Error) {
            recoverRoomCaptureSession(reason: "session-failure")
        }

        public func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
            true
        }

        private func refreshRoomMeshIfNeeded(force: Bool = false) {
            guard isMapView, let scene = scnView?.scene else { return }
            guard let roomSignature = currentRoomSignature() else { return }

            let now = CACurrentMediaTime()
            if !force && roomSignature == lastRoomMeshSignature {
                return
            }
            if !force && now - lastRoomMeshRefresh < 8.0 {
                return
            }
            lastRoomMeshRefresh = now
            lastRoomMeshSignature = roomSignature

            guard let fileURL = try? parent.roomScanner.exportCurrentRoomToUSDZ() else { return }
            guard let meshScene = try? SCNScene(url: fileURL, options: [.checkConsistency: false]) else { return }

            let newMeshRoot = SCNNode()
            newMeshRoot.name = "RoomPlanMesh"
            for child in meshScene.rootNode.childNodes {
                child.removeFromParentNode()
                newMeshRoot.addChildNode(child)
            }
            configureRoomMeshMaterials(root: newMeshRoot)

            roomMeshNode?.removeFromParentNode()
            roomMeshNode = newMeshRoot
            scene.rootNode.addChildNode(newMeshRoot)
        }

        private func currentRoomSignature() -> Int? {
            guard let room = parent.roomScanner.currentRoom ?? parent.roomScanner.finalResult else { return nil }

            var hasher = Hasher()
            hasher.combine(room.walls.count)
            hasher.combine(room.doors.count)
            hasher.combine(room.windows.count)
            hasher.combine(room.objects.count)
            for wall in room.walls.prefix(8) {
                hasher.combine(wall.identifier)
            }
            for object in room.objects.prefix(8) {
                hasher.combine(object.identifier)
            }
            return hasher.finalize()
        }

        private func configureRoomMeshMaterials(root: SCNNode) {
            root.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry else { return }
                for material in geometry.materials {
                    material.lightingModel = .physicallyBased
                    material.roughness.contents = NSNumber(value: 0.9)
                    material.metalness.contents = NSNumber(value: 0.05)
                    material.diffuse.contentsTransform = SCNMatrix4Identity
                }
            }
        }

        func updateRoomNodes() {
            guard !isMapView else { return }
            guard let scene = scnView?.scene, let room = parent.roomScanner.currentRoom else { return }

            var currentKeys = Set(roomNodes.keys)

            func updateNode(id: UUID, transform: simd_float4x4, dimensions: simd_float3, color: UIColor, opacity: CGFloat) {
                currentKeys.remove(id)
                if let existing = roomNodes[id] {
                    SCNTransaction.begin()
                    SCNTransaction.animationDuration = 0.25
                    existing.simdTransform = transform
                    SCNTransaction.commit()
                } else {
                    let box = SCNBox(
                        width: CGFloat(dimensions.x),
                        height: CGFloat(dimensions.y),
                        length: CGFloat(dimensions.z),
                        chamferRadius: 0.0
                    )
                    box.firstMaterial?.diffuse.contents = color
                    box.firstMaterial?.transparency = opacity
                    box.firstMaterial?.lightingModel = .physicallyBased
                    box.firstMaterial?.roughness.contents = NSNumber(value: 0.8)
                    box.firstMaterial?.metalness.contents = NSNumber(value: 0.2)

                    let node = SCNNode(geometry: box)
                    node.simdTransform = transform
                    node.isHidden = true
                    scene.rootNode.addChildNode(node)
                    roomNodes[id] = node
                }
            }

            let wallColor = UIColor.white
            let doorColor = UIColor(red: 0.7, green: 0.5, blue: 0.3, alpha: 1.0)
            let windowColor = UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 0.6)
            let objectColor = UIColor(white: 0.85, alpha: 1.0)

            for wall in room.walls {
                updateNode(id: wall.identifier, transform: wall.transform, dimensions: wall.dimensions, color: wallColor, opacity: 1.0)
            }
            for door in room.doors {
                updateNode(id: door.identifier, transform: door.transform, dimensions: door.dimensions, color: doorColor, opacity: 1.0)
            }
            for window in room.windows {
                updateNode(id: window.identifier, transform: window.transform, dimensions: window.dimensions, color: windowColor, opacity: 0.5)
            }
            for object in room.objects {
                updateNode(id: object.identifier, transform: object.transform, dimensions: object.dimensions, color: objectColor, opacity: 1.0)
            }

            for stale in currentKeys {
                roomNodes[stale]?.removeFromParentNode()
                roomNodes.removeValue(forKey: stale)
            }
        }

        func updateNodes() {
            guard scnView?.scene != nil else { return }
            let now = CACurrentMediaTime()
            let minimumRenderInterval: CFTimeInterval = isMapView ? 0.35 : 0.50
            guard now - lastNodeRenderTime >= minimumRenderInterval else { return }
            lastNodeRenderTime = now

            for node in apNodes.values {
                node.removeAllActions()
                node.removeFromParentNode()
            }
            apNodes.removeAll()

            if !isMapView {
                updateRoomNodes()
            }
        }

        func clearSurveyOverlayNodes() {
            for node in apNodes.values {
                node.removeAllActions()
                node.removeFromParentNode()
            }
            apNodes.removeAll()
        }
    }
}
#endif
