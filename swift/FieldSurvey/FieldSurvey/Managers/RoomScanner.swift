#if os(iOS)
import Foundation
import RoomPlan
import Combine
import os.log
import simd

/// Manages the RoomPlan LiDAR scanning session to build a physical 3D mesh
/// of the environment while walking the survey.
@available(iOS 16.0, *)
@MainActor
public class RoomScanner: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    @Published public var isScanning = false
    @Published public var finalResult: CapturedRoom? = nil
    @Published public var currentRoom: CapturedRoom? = nil
    
    // We act as the delegate for the RoomCaptureView wrapped in our SwiftUI view.
    private let logger = Logger(subsystem: "com.serviceradar.fieldsurvey", category: "RoomScanner")
    private weak var currentView: RoomCaptureView?
    private var lastCurrentRoomPublishTime: TimeInterval = 0
    private var pendingCurrentRoom: CapturedRoom?
    private var currentRoomPublishScheduled = false
    private let currentRoomPublishMinInterval: TimeInterval = 1.0
    
    public override init() { super.init() }
    
    public required init?(coder: NSCoder) {
        super.init()
    }
    
    public func encode(with coder: NSCoder) {
    }
    
    public func startSession(in view: RoomCaptureView) {
        self.currentView = view
        view.delegate = self
        view.captureSession.delegate = self
        
        let configuration = RoomCaptureSession.Configuration()
        view.captureSession.run(configuration: configuration)
        isScanning = true
        logger.info("RoomPlan session started via LiDAR.")
    }
    
    public func stopSession(in view: RoomCaptureView) {
        view.captureSession.stop()
        isScanning = false
        logger.info("RoomPlan session stopped.")
    }
    
    // MARK: - RoomCaptureSessionDelegate
    
    nonisolated public func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor [weak self] in
            self?.publishCurrentRoom(room)
        }
    }

    private func publishCurrentRoom(_ room: CapturedRoom) {
        let now = Date().timeIntervalSince1970
        guard now - lastCurrentRoomPublishTime >= currentRoomPublishMinInterval else {
            pendingCurrentRoom = room
            scheduleDeferredCurrentRoomPublish()
            return
        }

        lastCurrentRoomPublishTime = now
        pendingCurrentRoom = nil
        currentRoom = room
    }

    private func scheduleDeferredCurrentRoomPublish() {
        guard !currentRoomPublishScheduled else { return }
        currentRoomPublishScheduled = true
        let delay = max(0.1, currentRoomPublishMinInterval - (Date().timeIntervalSince1970 - lastCurrentRoomPublishTime))

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.currentRoomPublishScheduled = false
            guard let pending = self.pendingCurrentRoom else { return }
            self.pendingCurrentRoom = nil
            self.lastCurrentRoomPublishTime = Date().timeIntervalSince1970
            self.currentRoom = pending
        }
    }
    
    // MARK: - RoomCaptureViewDelegate
    
    nonisolated public func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error = error {
            Task { @MainActor [weak self] in
                guard let self else { return }
                logger.error("Capture processing error: \(error.localizedDescription)")

                // Auto-recover from tracking failures (e.g. moving too fast, poor lighting).
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    if isScanning, let view = currentView {
                        logger.info("Auto-recovering RoomPlan session after tracking failure...")
                        view.captureSession.stop()
                        let configuration = RoomCaptureSession.Configuration()
                        view.captureSession.run(configuration: configuration)
                    }
                }
            }
            return false
        }
        return true
    }
    
    nonisolated public func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if let error = error {
                logger.error("Final processing error: \(error.localizedDescription)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    if isScanning, let view = currentView {
                        logger.info("Auto-recovering RoomPlan session after final processing failure...")
                        view.captureSession.stop()
                        let configuration = RoomCaptureSession.Configuration()
                        view.captureSession.run(configuration: configuration)
                    }
                }
                return
            }

            finalResult = processedResult
            logger.info("Room scan completed. Captured \(processedResult.walls.count) walls and \(processedResult.objects.count) objects.")
        }
    }

    /// Exports the captured room to a USDZ file URL for backend upload.
    public func exportUSDZ() throws -> URL {
        guard let finalResult = finalResult else {
            throw NSError(domain: "RoomScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "No captured room available to export."])
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("RoomScan_\(UUID().uuidString).usdz")
        try finalResult.export(to: fileURL)
        return fileURL
    }
    
    /// Exports the live, in-progress room to a USDZ file URL for live Map View rendering.
    public func exportCurrentRoomToUSDZ() throws -> URL {
        guard let room = currentRoom ?? finalResult else {
            throw NSError(domain: "RoomScanner", code: 2, userInfo: [NSLocalizedDescriptionKey: "No room data available yet."])
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("LivePreview.usdz")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        try room.export(to: fileURL)
        return fileURL
    }

    /// Exports a top-down 2D floorplan projection in the ARKit x/z coordinate plane.
    public func exportCurrentFloorplanGeoJSON() throws -> URL {
        guard let room = currentRoom ?? finalResult else {
            throw NSError(domain: "RoomScanner", code: 3, userInfo: [NSLocalizedDescriptionKey: "No room data available yet."])
        }

        let features =
            room.walls.map { floorplanFeature(for: $0, kind: "wall") } +
            room.doors.map { floorplanFeature(for: $0, kind: "door") } +
            room.windows.map { floorplanFeature(for: $0, kind: "window") }

        let collection: [String: Any] = [
            "type": "FeatureCollection",
            "features": features,
            "properties": [
                "coordinate_system": "arkit_xz_meters",
                "source": "RoomPlan",
                "wall_count": room.walls.count,
                "door_count": room.doors.count,
                "window_count": room.windows.count
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: collection, options: [.prettyPrinted, .sortedKeys])
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("Floorplan2D_\(UUID().uuidString).geojson")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func floorplanFeature(for surface: CapturedRoom.Surface, kind: String) -> [String: Any] {
        let start = projectedPoint(surface.transform, xOffset: -surface.dimensions.x / 2)
        let end = projectedPoint(surface.transform, xOffset: surface.dimensions.x / 2)
        let center = projectedPoint(surface.transform, xOffset: 0)

        return [
            "type": "Feature",
            "geometry": [
                "type": "LineString",
                "coordinates": [
                    [Double(start.x), Double(start.y)],
                    [Double(end.x), Double(end.y)]
                ]
            ],
            "properties": [
                "id": surface.identifier.uuidString,
                "kind": kind,
                "width_m": Double(surface.dimensions.x),
                "height_m": Double(surface.dimensions.y),
                "center_x": Double(center.x),
                "center_z": Double(center.y)
            ]
        ]
    }

    private func projectedPoint(_ transform: simd_float4x4, xOffset: Float) -> SIMD2<Float> {
        let local = SIMD4<Float>(xOffset, 0, 0, 1)
        let world = transform * local
        return SIMD2<Float>(world.x, world.z)
    }
}
#endif
