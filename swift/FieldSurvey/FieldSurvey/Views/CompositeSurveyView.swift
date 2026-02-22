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
    public var onAPCandidateDetected: ((APLabelCandidate) -> Void)?

    public init(
        roomScanner: RoomScanner,
        wifiScanner: RealWiFiScanner,
        isMapView: Binding<Bool>,
        onAPCandidateDetected: ((APLabelCandidate) -> Void)? = nil
    ) {
        self.roomScanner = roomScanner
        self.wifiScanner = wifiScanner
        self._isMapView = isMapView
        self.onAPCandidateDetected = onAPCandidateDetected
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
        scnView.preferredFramesPerSecond = 30
        scnView.antialiasingMode = .multisampling2X
        scnView.isJitteringEnabled = false
        scnView.rendersContinuously = true

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

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSceneTap(_:)))
        tapGesture.numberOfTapsRequired = 1
        tapGesture.cancelsTouchesInView = false
        tapGesture.delaysTouchesBegan = false
        tapGesture.delaysTouchesEnded = false
        tapGesture.delegate = context.coordinator
        scnView.addGestureRecognizer(tapGesture)

        context.coordinator.container = container
        context.coordinator.roomView = roomView
        context.coordinator.scnView = scnView
        context.coordinator.cameraNode = cameraNode
        context.coordinator.mapCameraNode = mapCameraNode
        context.coordinator.tapGesture = tapGesture

        context.coordinator.setupBackgroundObservers()
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
        coordinator.teardownARPriorityMode()
        coordinator.removeBackgroundObservers()
        coordinator.stopDisplayLink()
        coordinator.roomView?.captureSession.stop()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    public class Coordinator: NSObject, @preconcurrency ARSessionDelegate, UIGestureRecognizerDelegate {
        var parent: CompositeSurveyView
        var wifiScanner: RealWiFiScanner?
        var isMapView: Bool = false

        weak var container: UIView?
        weak var roomView: RoomCaptureView?
        weak var scnView: SCNView?
        weak var tapGesture: UITapGestureRecognizer?

        var cameraNode: SCNNode?
        var mapCameraNode: SCNNode?

        private var displayLink: CADisplayLink?
        private var apNodes: [String: SCNNode] = [:]
        private var heatmapNodes: [String: SCNNode] = [:]
        private var roomNodes: [UUID: SCNNode] = [:]

        private var roomMeshNode: SCNNode?
        private var lastRoomMeshRefresh: CFTimeInterval = 0
        private var lastRoomMeshSignature: Int?

        private var previousMapState = false

        private let objectDetector = APObjectDetector()
        private var isAutoDetectionInFlight = false
        private var lastAutoDetectionTime: CFTimeInterval = 0
        private var recentHaloPositions: [SIMD3<Float>] = []
        private var lastLandmarkHaloByID: [String: CFTimeInterval] = [:]
        private var lastSessionRecoveryTime: CFTimeInterval = 0
        private var nilFrameStartTime: CFTimeInterval?
        private var needsSessionRecoveryOnForeground = false
        private var lastARFrameTimestamp: TimeInterval = 0
        private var staleTimestampStartTime: CFTimeInterval?
        private var trackingUnavailableStartTime: CFTimeInterval?
        private var enteredBackgroundAt: CFTimeInterval?
        private var lastSessionStartTime: CFTimeInterval = CACurrentMediaTime()
        private var isAppActive = true
        private var cachedRoomBoundsSignature: Int?
        private var cachedRoomBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
        private var arPriorityLoadShedActive = false
        private var arPriorityStableSince: CFTimeInterval?
        private var lastARPriorityTransitionTime: CFTimeInterval = 0

        private struct APNodeRenderProfile {
            let maxNodes: Int
            let dedupeBySSID: Bool
            let maxAgeSeconds: TimeInterval
            let showCoverage: Bool
            let showWaveEmitters: Bool
            let showLabels: Bool
            let sphereSegments: Int
            let convergeAlpha: Float
        }

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
            scnView?.isPlaying = false
            needsSessionRecoveryOnForeground = true
        }

        @objc func appDidEnterBackground() {
            isAppActive = false
            enteredBackgroundAt = CACurrentMediaTime()
            stopDisplayLink()
            scnView?.isPlaying = false
            needsSessionRecoveryOnForeground = true
        }

        @objc func appWillEnterForeground() {
            isAppActive = false
        }

        @objc func appDidBecomeActive() {
            isAppActive = true
            startDisplayLink()
            scnView?.isPlaying = true

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
            displayLink?.add(to: .main, forMode: .common)
        }

        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc func handleSceneTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let scnView = scnView else { return }
            let tapPoint = recognizer.location(in: scnView)
            runTapAssistDetection(at: tapPoint)
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Do not intercept map camera gestures with AR tap assist.
            !isMapView
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func updateCamera() {
            guard let roomView = roomView, let scnView = scnView, let cameraNode = cameraNode, let mapCameraNode = mapCameraNode else { return }

            if isMapView {
                maybeUpdateARPriorityMode(isTrackingHealthy: true, now: CACurrentMediaTime())
                roomView.isHidden = true
                scnView.allowsCameraControl = true
                tapGesture?.isEnabled = false

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
            } else {
                roomView.isHidden = false
                scnView.allowsCameraControl = false
                tapGesture?.isEnabled = true

                if scnView.pointOfView != cameraNode {
                    scnView.pointOfView = cameraNode
                }

                roomMeshNode?.isHidden = true
                for node in roomNodes.values {
                    node.isHidden = true
                }

                if let frame = roomView.captureSession.arSession.currentFrame {
                    nilFrameStartTime = nil
                    monitorFrameLiveness(frame)
                    cameraNode.simdTransform = frame.camera.transform
                    cameraNode.camera?.projectionTransform = SCNMatrix4(frame.camera.projectionMatrix)
                    let cameraPos = SIMD3<Float>(
                        frame.camera.transform.columns.3.x,
                        frame.camera.transform.columns.3.y,
                        frame.camera.transform.columns.3.z
                    )
                    let cameraForward = SIMD3<Float>(
                        -frame.camera.transform.columns.2.x,
                        -frame.camera.transform.columns.2.y,
                        -frame.camera.transform.columns.2.z
                    )
                    wifiScanner?.updateDevicePose(position: cameraPos)
                    wifiScanner?.queueHeatmapCaptureFromCurrentPose(position: cameraPos)
                    maybeRunAutoDetection(frame: frame)
                    maybeHighlightManualLandmarks(cameraPosition: cameraPos, cameraForward: cameraForward)
                } else {
                    maybeRecoverMissingARFrames()
                }
            }

            previousMapState = isMapView
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
                BLEScanner.shared.stopScanning()
                SubnetScanner.shared.stopScanning()
            } else {
                guard SettingsManager.shared.rfScanningEnabled else { return }
                wifiScanner?.startScanning()
                if SettingsManager.shared.showBLEBeacons {
                    BLEScanner.shared.startScanning()
                } else {
                    BLEScanner.shared.stopScanning()
                    wifiScanner?.setBLEIngestionEnabled(false)
                }
                SubnetScanner.shared.startScanning()
            }

            print("FieldSurvey AR Priority \(active ? "ON" : "OFF"): \(reason)")
        }

        func teardownARPriorityMode() {
            if arPriorityLoadShedActive {
                setARPriorityLoadShed(active: false, reason: "view-dismantle")
            } else {
                SettingsManager.shared.setARPriorityLoadShedActive(false)
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

        private func maybeRunAutoDetection(frame: ARFrame) {
            guard SettingsManager.shared.aiObjectDetectionEnabled else { return }
            guard !arPriorityLoadShedActive else { return }
            guard objectDetector.isAvailable else { return }

            let now = CACurrentMediaTime()
            guard now - lastAutoDetectionTime > 1.35 else { return }
            guard !isAutoDetectionInFlight else { return }

            isAutoDetectionInFlight = true
            lastAutoDetectionTime = now

            objectDetector.detectAccessPoints(in: frame.capturedImage) { [weak self] detections in
                guard let self else { return }
                self.isAutoDetectionInFlight = false
                self.applyAutomaticDetections(detections)
            }
        }

        private func maybeHighlightManualLandmarks(cameraPosition: SIMD3<Float>, cameraForward: SIMD3<Float>) {
            guard let wifiScanner else { return }

            let now = CACurrentMediaTime()
            let forwardLength = simd_length(cameraForward)
            guard forwardLength > 0.0001 else { return }
            let normalizedForward = cameraForward / forwardLength

            for landmark in wifiScanner.manualAPLandmarks {
                let delta = landmark.position - cameraPosition
                let distance = simd_length(delta)
                guard distance > 0.35 && distance < 9.0 else { continue }

                let direction = delta / distance
                let alignment = simd_dot(direction, normalizedForward)
                guard alignment > 0.9 else { continue }

                let cooldown = now - (lastLandmarkHaloByID[landmark.id] ?? 0)
                guard cooldown > 2.2 else { continue }

                addHalo(at: landmark.position, color: .systemGreen, title: landmark.label)
                lastLandmarkHaloByID[landmark.id] = now
            }
        }

        private func applyAutomaticDetections(_ detections: [APObjectDetectionResult]) {
            guard let scnView = scnView else { return }

            for detection in detections.prefix(3) where detection.confidence >= 0.55 {
                let center = CGPoint(
                    x: detection.boundingBox.midX * scnView.bounds.width,
                    y: (1.0 - detection.boundingBox.midY) * scnView.bounds.height
                )

                guard let worldPosition = worldPosition(fromScreenPoint: center, distance: 2.2) else { continue }
                guard !isNearRecentHalo(position: worldPosition, threshold: 0.75) else { continue }

                addHalo(at: worldPosition, color: .systemTeal, title: detection.label)
                rememberHaloPosition(worldPosition)
            }
        }

        private func runTapAssistDetection(at tapPoint: CGPoint) {
            guard let roomView = roomView else { return }
            guard let frame = roomView.captureSession.arSession.currentFrame else { return }
            guard let worldPosition = worldPositionForTap(tapPoint) else { return }

            guard SettingsManager.shared.aiObjectDetectionEnabled, objectDetector.isAvailable, let scnView = scnView else {
                addHalo(at: worldPosition, color: .systemOrange, title: "AP Candidate")
                parent.onAPCandidateDetected?(
                    APLabelCandidate(
                        suggestedLabel: "AP Candidate",
                        confidence: 0.55,
                        worldPosition: worldPosition,
                        source: .tapAssist
                    )
                )
                return
            }

            let normalizedTap = CGPoint(
                x: tapPoint.x / max(scnView.bounds.width, 1),
                y: 1.0 - (tapPoint.y / max(scnView.bounds.height, 1))
            )

            objectDetector.detectAccessPoints(in: frame.capturedImage) { [weak self] detections in
                guard let self else { return }

                let nearest = detections.min { lhs, rhs in
                    let lhsCenter = CGPoint(x: lhs.boundingBox.midX, y: lhs.boundingBox.midY)
                    let rhsCenter = CGPoint(x: rhs.boundingBox.midX, y: rhs.boundingBox.midY)
                    let lhsDist = hypot(lhsCenter.x - normalizedTap.x, lhsCenter.y - normalizedTap.y)
                    let rhsDist = hypot(rhsCenter.x - normalizedTap.x, rhsCenter.y - normalizedTap.y)
                    return lhsDist < rhsDist
                }

                let nearestCenter = nearest.map { CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY) }
                let nearestDistance = nearestCenter.map { hypot($0.x - normalizedTap.x, $0.y - normalizedTap.y) } ?? .greatestFiniteMagnitude

                let selectedLabel: String
                let selectedConfidence: Double
                if let nearest, nearestDistance < 0.35 {
                    selectedLabel = nearest.label
                    selectedConfidence = nearest.confidence
                } else {
                    selectedLabel = "AP Candidate"
                    selectedConfidence = 0.6
                }

                self.addHalo(at: worldPosition, color: .systemOrange, title: selectedLabel)
                self.parent.onAPCandidateDetected?(
                    APLabelCandidate(
                        suggestedLabel: selectedLabel,
                        confidence: selectedConfidence,
                        worldPosition: worldPosition,
                        source: .tapAssist
                    )
                )
            }
        }

        private func isNearRecentHalo(position: SIMD3<Float>, threshold: Float) -> Bool {
            recentHaloPositions.contains { simd_distance($0, position) < threshold }
        }

        private func rememberHaloPosition(_ position: SIMD3<Float>) {
            recentHaloPositions.append(position)
            if recentHaloPositions.count > 20 {
                recentHaloPositions.removeFirst(recentHaloPositions.count - 20)
            }
        }

        private func worldPositionForTap(_ point: CGPoint) -> SIMD3<Float>? {
            if let roomView {
                let session = roomView.captureSession.arSession
                if let frame = session.currentFrame {
                    let queryExisting = frame.raycastQuery(from: point, allowing: .existingPlaneGeometry, alignment: .any)
                    if let hit = session.raycast(queryExisting).first {
                        return SIMD3<Float>(
                            hit.worldTransform.columns.3.x,
                            hit.worldTransform.columns.3.y,
                            hit.worldTransform.columns.3.z
                        )
                    }
                    let queryEstimatedAny = frame.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any)
                    if let hit = session.raycast(queryEstimatedAny).first {
                        return SIMD3<Float>(
                            hit.worldTransform.columns.3.x,
                            hit.worldTransform.columns.3.y,
                            hit.worldTransform.columns.3.z
                        )
                    }
                    let queryEstimatedHorizontal = frame.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .horizontal)
                    if let hit = session.raycast(queryEstimatedHorizontal).first {
                        return SIMD3<Float>(
                            hit.worldTransform.columns.3.x,
                            hit.worldTransform.columns.3.y,
                            hit.worldTransform.columns.3.z
                        )
                    }
                }
            }
            return worldPosition(fromScreenPoint: point, distance: 2.0)
        }

        private func worldPosition(fromScreenPoint point: CGPoint, distance: Float) -> SIMD3<Float>? {
            guard let scnView = scnView, let pov = scnView.pointOfView else { return nil }

            let flippedY = scnView.bounds.height - point.y
            let nearPoint = scnView.unprojectPoint(SCNVector3(point.x, flippedY, 0.0))
            let farPoint = scnView.unprojectPoint(SCNVector3(point.x, flippedY, 1.0))

            let nearVec = SIMD3<Float>(nearPoint.x, nearPoint.y, nearPoint.z)
            let farVec = SIMD3<Float>(farPoint.x, farPoint.y, farPoint.z)
            let ray = farVec - nearVec
            let rayLength = simd_length(ray)
            guard rayLength > 0.0001 else { return nil }

            let direction = ray / rayLength
            let camPos = pov.simdWorldPosition
            return camPos + direction * distance
        }

        private func addHalo(at position: SIMD3<Float>, color: UIColor, title: String) {
            guard let scene = scnView?.scene else { return }

            let haloNode = SCNNode()
            haloNode.simdPosition = position

            let ring = SCNTorus(ringRadius: 0.28, pipeRadius: 0.022)
            ring.firstMaterial?.diffuse.contents = color
            ring.firstMaterial?.emission.contents = color
            ring.firstMaterial?.emission.intensity = 1.4
            ring.firstMaterial?.lightingModel = .physicallyBased

            let ringNode = SCNNode(geometry: ring)
            ringNode.eulerAngles = SCNVector3(Float.pi / 2.0, 0, 0)
            haloNode.addChildNode(ringNode)

            let text = SCNText(string: title, extrusionDepth: 0.0)
            text.font = UIFont.systemFont(ofSize: 0.08, weight: .semibold)
            text.firstMaterial?.diffuse.contents = UIColor.white
            text.firstMaterial?.emission.contents = UIColor.white
            text.firstMaterial?.emission.intensity = 0.9

            let textNode = SCNNode(geometry: text)
            textNode.scale = SCNVector3(0.65, 0.65, 0.65)
            textNode.position = SCNVector3(-0.22, 0.18, 0)
            textNode.constraints = [SCNBillboardConstraint()]
            haloNode.addChildNode(textNode)

            let pulseOut = SCNAction.scale(to: 1.15, duration: 0.35)
            let pulseIn = SCNAction.scale(to: 0.98, duration: 0.35)
            let fade = SCNAction.fadeOut(duration: 1.2)
            let sequence = SCNAction.sequence([
                SCNAction.repeat(SCNAction.sequence([pulseOut, pulseIn]), count: 4),
                fade,
                SCNAction.removeFromParentNode()
            ])
            haloNode.runAction(sequence)

            scene.rootNode.addChildNode(haloNode)
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

        private func profileForCurrentMode() -> APNodeRenderProfile {
            if isMapView {
                return APNodeRenderProfile(
                    maxNodes: 18,
                    dedupeBySSID: false,
                    maxAgeSeconds: 48,
                    showCoverage: true,
                    showWaveEmitters: false,
                    showLabels: true,
                    sphereSegments: 20,
                    convergeAlpha: 0.24
                )
            }

            if arPriorityLoadShedActive {
                return APNodeRenderProfile(
                    maxNodes: 4,
                    dedupeBySSID: true,
                    maxAgeSeconds: 12,
                    showCoverage: false,
                    showWaveEmitters: false,
                    showLabels: false,
                    sphereSegments: 12,
                    convergeAlpha: 0.08
                )
            }

            return APNodeRenderProfile(
                maxNodes: 10,
                dedupeBySSID: true,
                maxAgeSeconds: 24,
                showCoverage: false,
                showWaveEmitters: false,
                showLabels: true,
                sphereSegments: 20,
                convergeAlpha: 0.14
            )
        }

        private func renderCandidates(
            from allSamples: [SurveySample],
            showBLE: Bool,
            profile: APNodeRenderProfile
        ) -> [SurveySample] {
            let now = Date().timeIntervalSince1970
            let filtered = allSamples.filter { sample in
                let isBLE = sample.securityType == "BLE"
                if !showBLE && isBLE {
                    return false
                }
                if sample.bssid.hasPrefix("mdns-") || sample.securityType == "mDNS Device" {
                    return false
                }
                if sample.frequency <= 0 {
                    return false
                }
                if now - sample.timestamp > profile.maxAgeSeconds {
                    return false
                }
                return true
            }

            let sorted = filtered.sorted { lhs, rhs in
                if lhs.rssi == rhs.rssi {
                    return lhs.timestamp > rhs.timestamp
                }
                return lhs.rssi > rhs.rssi
            }

            guard profile.dedupeBySSID else {
                return Array(sorted.prefix(profile.maxNodes))
            }

            var selected: [SurveySample] = []
            var seenSSIDs = Set<String>()
            for sample in sorted {
                let normalizedSSID = sample.ssid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let groupingKey = normalizedSSID.isEmpty ? sample.bssid.lowercased() : normalizedSSID
                if seenSSIDs.contains(groupingKey) {
                    continue
                }
                seenSSIDs.insert(groupingKey)
                selected.append(sample)
                if selected.count >= profile.maxNodes {
                    break
                }
            }
            return selected
        }

        private func createAPNode(sample: SurveySample, profile: APNodeRenderProfile) -> SCNNode {
            let container = SCNNode()
            container.name = "Container_\(sample.bssid)"

            let is5G = sample.frequency > 4000
            let color = is5G ? UIColor.cyan : UIColor.orange

            let core = SCNSphere(radius: 0.15)
            core.segmentCount = profile.sphereSegments
            core.firstMaterial?.diffuse.contents = color
            core.firstMaterial?.emission.contents = color
            core.firstMaterial?.emission.intensity = 2.0
            let coreNode = SCNNode(geometry: core)
            coreNode.name = "Core"
            container.addChildNode(coreNode)

            let coverage = SCNSphere(radius: 2.0)
            coverage.segmentCount = max(16, profile.sphereSegments - 8)
            coverage.firstMaterial?.diffuse.contents = color
            coverage.firstMaterial?.emission.contents = color
            coverage.firstMaterial?.emission.intensity = 0.5
            coverage.firstMaterial?.transparent.contents = UIColor(white: 1.0, alpha: 0.15)
            coverage.firstMaterial?.isDoubleSided = false
            coverage.firstMaterial?.writesToDepthBuffer = false
            coverage.firstMaterial?.blendMode = .alpha
            let coverageNode = SCNNode(geometry: coverage)
            coverageNode.name = "Coverage"
            coverageNode.isHidden = !profile.showCoverage
            container.addChildNode(coverageNode)

            if profile.showWaveEmitters {
                addRFWaveEmitters(to: container, color: color)
            }

            let label = sample.ssid.isEmpty ? sample.bssid : sample.ssid
            let displayLabel = label.count > 24 ? "\(label.prefix(24))…" : label
            let text = SCNText(string: displayLabel, extrusionDepth: 0.0)
            text.font = UIFont.systemFont(ofSize: 0.1, weight: .medium)
            text.firstMaterial?.diffuse.contents = UIColor.white
            text.firstMaterial?.emission.contents = UIColor.white
            text.firstMaterial?.emission.intensity = 1.0
            text.flatness = 0.2

            let textNode = SCNNode(geometry: text)
            textNode.name = "Label"
            let (min, max) = textNode.boundingBox
            textNode.pivot = SCNMatrix4MakeTranslation((max.x - min.x) / 2, (max.y - min.y) / 2, 0)
            textNode.scale = SCNVector3(0.9, 0.9, 0.9)
            textNode.position = SCNVector3(0, 0.4, 0)
            textNode.isHidden = !profile.showLabels
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            textNode.constraints = [billboard]
            container.addChildNode(textNode)

            return container
        }

        private func applyRenderProfile(_ profile: APNodeRenderProfile, to node: SCNNode, sample: SurveySample) {
            if let coverage = node.childNode(withName: "Coverage", recursively: false) {
                coverage.isHidden = !profile.showCoverage
            }

            if let labelNode = node.childNode(withName: "Label", recursively: false) {
                labelNode.isHidden = !profile.showLabels
                if let labelText = labelNode.geometry as? SCNText {
                    let label = sample.ssid.isEmpty ? sample.bssid : sample.ssid
                    let displayLabel = label.count > 24 ? "\(label.prefix(24))…" : label
                    if (labelText.string as? String) != displayLabel {
                        labelText.string = displayLabel
                    }
                }
            }

            if profile.showWaveEmitters {
                let existingWaveNodes = node.childNodes.filter { $0.name?.hasPrefix("Wave_") == true }
                if existingWaveNodes.isEmpty {
                    let is5G = sample.frequency > 4000
                    let color = is5G ? UIColor.cyan : UIColor.orange
                    addRFWaveEmitters(to: node, color: color)
                }
            } else {
                for waveNode in node.childNodes where waveNode.name?.hasPrefix("Wave_") == true {
                    waveNode.removeAllActions()
                    waveNode.removeFromParentNode()
                }
            }
        }

        private func addRFWaveEmitters(to node: SCNNode, color: UIColor) {
            for waveIndex in 0..<3 {
                let wave = SCNTorus(ringRadius: 0.26, pipeRadius: 0.008)
                wave.firstMaterial?.diffuse.contents = color
                wave.firstMaterial?.emission.contents = color
                wave.firstMaterial?.emission.intensity = 1.0
                wave.firstMaterial?.writesToDepthBuffer = false
                wave.firstMaterial?.transparency = 0.8

                let waveNode = SCNNode(geometry: wave)
                waveNode.name = "Wave_\(waveIndex)"
                waveNode.eulerAngles = SCNVector3(Float.pi / 2.0, 0, 0)
                waveNode.opacity = 0.0
                node.addChildNode(waveNode)

                let delay = SCNAction.wait(duration: Double(waveIndex) * 0.42)
                let show = SCNAction.fadeOpacity(to: 0.65, duration: 0.1)
                let grow = SCNAction.scale(to: 6.6, duration: 1.45)
                let fade = SCNAction.fadeOut(duration: 1.45)
                let animate = SCNAction.group([grow, fade])
                let reset = SCNAction.run { waveNode in
                    waveNode.scale = SCNVector3(1, 1, 1)
                }

                waveNode.runAction(
                    SCNAction.repeatForever(
                        SCNAction.sequence([delay, show, animate, reset])
                    )
                )
            }
        }

        private func updateHeatmapNodes() {
            guard let scene = scnView?.scene, let wifiScanner else { return }
            guard isMapView else {
                for node in heatmapNodes.values {
                    node.isHidden = true
                }
                return
            }

            if !SettingsManager.shared.showWiFiHeatmap {
                for node in heatmapNodes.values {
                    node.isHidden = true
                }
                return
            }

            let points = Array(wifiScanner.heatmapPoints.suffix(1400))
            if points.isEmpty {
                for node in heatmapNodes.values {
                    node.isHidden = true
                }
                return
            }

            struct Bucket {
                var positionSum: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
                var rssiSum: Double = 0
                var count: Int = 0
            }

            let cellSize: Float = 0.45
            var buckets: [String: Bucket] = [:]
            for point in points {
                let xi = Int((point.position.x / cellSize).rounded())
                let zi = Int((point.position.z / cellSize).rounded())
                let key = "\(xi)_\(zi)"
                var bucket = buckets[key] ?? Bucket()
                bucket.positionSum += point.position
                bucket.rssiSum += point.rssi
                bucket.count += 1
                buckets[key] = bucket
            }

            var activeKeys = Set<String>()
            for (key, bucket) in buckets {
                guard bucket.count > 0 else { continue }
                activeKeys.insert(key)

                let avgPos = bucket.positionSum / Float(bucket.count)
                let avgRssi = bucket.rssiSum / Double(bucket.count)
                let strength = normalizedSignalStrength(avgRssi)
                let color = heatmapColor(for: strength)
                let displayPos = SIMD3<Float>(avgPos.x, avgPos.y - 1.0, avgPos.z)
                let scale = 0.25 + (strength * 1.8)
                let opacity = 0.12 + (strength * 0.55)

                if let node = heatmapNodes[key], let sphere = node.geometry as? SCNSphere {
                    node.isHidden = false
                    node.simdPosition = displayPos
                    node.scale = SCNVector3(scale, scale, scale)
                    node.opacity = CGFloat(opacity)
                    sphere.firstMaterial?.diffuse.contents = color
                    sphere.firstMaterial?.emission.contents = color
                } else {
                    let sphere = SCNSphere(radius: 0.12)
                    sphere.firstMaterial?.lightingModel = .physicallyBased
                    sphere.firstMaterial?.diffuse.contents = color
                    sphere.firstMaterial?.emission.contents = color
                    sphere.firstMaterial?.emission.intensity = 0.75
                    sphere.firstMaterial?.writesToDepthBuffer = false
                    sphere.firstMaterial?.transparency = 0.6

                    let node = SCNNode(geometry: sphere)
                    node.simdPosition = displayPos
                    node.scale = SCNVector3(scale, scale, scale)
                    node.opacity = CGFloat(opacity)
                    scene.rootNode.addChildNode(node)
                    heatmapNodes[key] = node
                }
            }

            for (key, node) in heatmapNodes where !activeKeys.contains(key) {
                node.isHidden = true
            }
        }

        private func normalizedSignalStrength(_ rssi: Double) -> Float {
            let normalized = (rssi + 90.0) / 45.0
            return Float(min(max(normalized, 0.0), 1.0))
        }

        private func heatmapColor(for strength: Float) -> UIColor {
            let hue = CGFloat(0.66 - (0.66 * strength))
            return UIColor(hue: hue, saturation: 0.95, brightness: 1.0, alpha: 1.0)
        }

        private func normalizedHorizontal(_ vector: SIMD3<Float>) -> SIMD3<Float>? {
            let flattened = SIMD3<Float>(vector.x, 0, vector.z)
            let length = simd_length(flattened)
            guard length > 0.0001 else { return nil }
            return flattened / length
        }

        private func cachedRoomBoundsForProjection() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
            guard let room = parent.roomScanner.currentRoom ?? parent.roomScanner.finalResult else {
                cachedRoomBounds = nil
                cachedRoomBoundsSignature = nil
                return nil
            }

            let signature = currentRoomSignature()
            if cachedRoomBoundsSignature == signature, let cachedRoomBounds {
                return cachedRoomBounds
            }

            var minPoint = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
            var maxPoint = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
            var found = false

            func include(transform: simd_float4x4, dimensions: simd_float3) {
                let center = SIMD3<Float>(
                    transform.columns.3.x,
                    transform.columns.3.y,
                    transform.columns.3.z
                )
                let half = SIMD3<Float>(
                    max(dimensions.x * 0.5, 0.05),
                    max(dimensions.y * 0.5, 0.05),
                    max(dimensions.z * 0.5, 0.05)
                )
                minPoint = simd_min(minPoint, center - half)
                maxPoint = simd_max(maxPoint, center + half)
                found = true
            }

            for wall in room.walls {
                include(transform: wall.transform, dimensions: wall.dimensions)
            }
            for door in room.doors {
                include(transform: door.transform, dimensions: door.dimensions)
            }
            for window in room.windows {
                include(transform: window.transform, dimensions: window.dimensions)
            }
            for object in room.objects {
                include(transform: object.transform, dimensions: object.dimensions)
            }

            guard found else {
                cachedRoomBounds = nil
                cachedRoomBoundsSignature = signature
                return nil
            }

            let bounds = (min: minPoint, max: maxPoint)
            cachedRoomBounds = bounds
            cachedRoomBoundsSignature = signature
            return bounds
        }

        private func clampedProjectedY(_ y: Float, cameraY: Float, isBLE: Bool) -> Float {
            let fallbackSpan: Float = isBLE ? 0.7 : 1.1
            var minY = cameraY - fallbackSpan
            var maxY = cameraY + fallbackSpan

            if let bounds = cachedRoomBoundsForProjection() {
                let boundedMin = bounds.min.y + 0.15
                let boundedMax = bounds.max.y - 0.15
                if boundedMax > boundedMin {
                    minY = max(minY, boundedMin)
                    maxY = min(maxY, boundedMax)
                }
            }

            if maxY <= minY {
                return cameraY
            }
            return min(max(y, minY), maxY)
        }

        func updateNodes() {
            guard let scnView = scnView, let scene = scnView.scene, let wifiScanner = wifiScanner else { return }
            let frame = roomView?.captureSession.arSession.currentFrame

            let cameraPos: SIMD3<Float>
            let cameraForward: SIMD3<Float>
            if let frame {
                let cameraTransform = frame.camera.transform
                cameraPos = SIMD3<Float>(
                    cameraTransform.columns.3.x,
                    cameraTransform.columns.3.y,
                    cameraTransform.columns.3.z
                )
                cameraForward = SIMD3<Float>(
                    -cameraTransform.columns.2.x,
                    -cameraTransform.columns.2.y,
                    -cameraTransform.columns.2.z
                )
            } else if let pov = scnView.pointOfView {
                cameraPos = pov.simdWorldPosition
                cameraForward = pov.simdWorldFront * -1.0
            } else {
                cameraPos = SIMD3<Float>(0, 0, 0)
                cameraForward = SIMD3<Float>(0, 0, -1)
            }

            let horizontalForward = normalizedHorizontal(cameraForward) ?? SIMD3<Float>(0, 0, -1)

            let showBLE = SettingsManager.shared.showBLEBeacons
            let profile = profileForCurrentMode()
            let samples = renderCandidates(
                from: Array(wifiScanner.accessPoints.values),
                showBLE: showBLE,
                profile: profile
            )
            var currentKeys = Set(apNodes.keys)

            for sample in samples {
                let key = sample.bssid
                let isBLE = sample.securityType == "BLE"

                if !showBLE && isBLE {
                    continue
                }

                currentKeys.remove(key)

                let txPower = sample.frequency > 4000 ? -45.0 : -35.0
                let n = 3.0
                let estimatedDistance = Float(pow(10.0, (txPower - sample.rssi) / (10.0 * n)))
                let clampedDistance = min(max(estimatedDistance, 0.5), 15.0)
                let resolvedPosition = wifiScanner.resolvedAPLocations[key]?.position

                var newTargetPos: SIMD3<Float>

                if let existingNode = apNodes[key] {
                    let currentPos = existingNode.simdPosition
                    if let resolvedPosition {
                        newTargetPos = resolvedPosition
                    } else {
                        let vectorToNode = currentPos - cameraPos
                        let direction = normalizedHorizontal(vectorToNode) ?? horizontalForward
                        newTargetPos = cameraPos + (direction * clampedDistance)
                        let anchoredY = abs(currentPos.y - cameraPos.y) < 1.8 ? currentPos.y : cameraPos.y
                        newTargetPos.y = clampedProjectedY(anchoredY, cameraY: cameraPos.y, isBLE: isBLE)
                    }

                    if resolvedPosition != nil {
                        newTargetPos.y = clampedProjectedY(newTargetPos.y, cameraY: cameraPos.y, isBLE: isBLE)
                    }

                    if newTargetPos.x.isNaN || newTargetPos.y.isNaN || newTargetPos.z.isNaN {
                        continue
                    }

                    let scale = max(0.2, min(1.5, Float(sample.rssi + 100) / 60.0))
                    let alpha: Float = resolvedPosition == nil ? 0.02 : profile.convergeAlpha
                    var convergedPos = currentPos * (1.0 - alpha) + newTargetPos * alpha
                    convergedPos.y = clampedProjectedY(convergedPos.y, cameraY: cameraPos.y, isBLE: isBLE)
                    let finalConvergedPos = convergedPos

                    let moveAction = SCNAction.move(to: SCNVector3(finalConvergedPos), duration: 0.5)
                    moveAction.timingMode = .easeOut
                    existingNode.runAction(moveAction, forKey: "ap-move")
                    applyRenderProfile(profile, to: existingNode, sample: sample)

                    if let core = existingNode.childNode(withName: "Core", recursively: false) {
                        core.runAction(SCNAction.scale(to: CGFloat(scale), duration: 0.5), forKey: "core-scale")
                    }
                    if let coverage = existingNode.childNode(withName: "Coverage", recursively: false) {
                        let currentScale = coverage.scale.x
                        let newScale = max(0.3, currentScale * 0.98)
                        coverage.runAction(SCNAction.scale(to: CGFloat(newScale), duration: 0.5), forKey: "coverage-scale")

                        let currentOpacity = coverage.opacity
                        let newOpacity = min(1.0, currentOpacity + 0.01)
                        coverage.runAction(SCNAction.fadeOpacity(to: CGFloat(newOpacity), duration: 0.5), forKey: "coverage-opacity")
                    }

                    DispatchQueue.main.async {
                        self.wifiScanner?.apPositions[key] = finalConvergedPos
                    }
                } else {
                    if let resolvedPosition {
                        newTargetPos = resolvedPosition
                    } else {
                        newTargetPos = cameraPos + (horizontalForward * clampedDistance)
                        newTargetPos.y = clampedProjectedY(cameraPos.y, cameraY: cameraPos.y, isBLE: isBLE)
                    }

                    if resolvedPosition != nil {
                        newTargetPos.y = clampedProjectedY(newTargetPos.y, cameraY: cameraPos.y, isBLE: isBLE)
                    }

                    if newTargetPos.x.isNaN || newTargetPos.y.isNaN || newTargetPos.z.isNaN {
                        continue
                    }

                    let node = createAPNode(sample: sample, profile: profile)
                    node.simdPosition = newTargetPos
                    scene.rootNode.addChildNode(node)
                    apNodes[key] = node

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

            updateHeatmapNodes()

            if !isMapView {
                updateRoomNodes()
            }
        }
    }
}
#endif
