#if os(iOS)
import Foundation
import RoomPlan
import Combine
import os.log

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
    
    public func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        publishCurrentRoom(room)
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
    
    public func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error = error {
            logger.error("Capture processing error: \(error.localizedDescription)")
            
            // Auto-recover from tracking failures (e.g. moving too fast, poor lighting)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if self.isScanning, let view = self.currentView {
                    self.logger.info("Auto-recovering RoomPlan session after tracking failure...")
                    view.captureSession.stop()
                    let configuration = RoomCaptureSession.Configuration()
                    view.captureSession.run(configuration: configuration)
                }
            }
            return false
        }
        return true
    }
    
    public func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error = error {
            logger.error("Final processing error: \(error.localizedDescription)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if self.isScanning, let view = self.currentView {
                    self.logger.info("Auto-recovering RoomPlan session after final processing failure...")
                    view.captureSession.stop()
                    let configuration = RoomCaptureSession.Configuration()
                    view.captureSession.run(configuration: configuration)
                }
            }
            return
        }
        
        DispatchQueue.main.async {
            self.finalResult = processedResult
            self.logger.info("Room scan completed. Captured \(processedResult.walls.count) walls and \(processedResult.objects.count) objects.")
            
            // Automatically export and upload the USDZ mesh payload for the God-View backend
            Task {
                do {
                    let fileURL = try self.exportUSDZ()
                    self.uploadUSDZ(fileURL: fileURL, sessionID: UUID().uuidString)
                } catch {
                    self.logger.error("Failed to export USDZ for upload: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Streams the captured USDZ physical environment model to the ServiceRadar backend.
    private func uploadUSDZ(fileURL: URL, sessionID: String) {
        guard let url = URL(string: "https://serviceradar-api.internal/v1/topology/physical-mesh/\(sessionID)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("model/vnd.usdz+zip", forHTTPHeaderField: "Content-Type")
        
        do {
            let data = try Data(contentsOf: fileURL)
            request.httpBody = data
            
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                if let error = error {
                    self?.logger.error("USDZ upload failed: \(error.localizedDescription)")
                } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    self?.logger.error("USDZ upload rejected by server: HTTP \(httpResponse.statusCode)")
                } else {
                    self?.logger.info("Successfully pushed physical USDZ mesh to backend God-View.")
                }
            }
            task.resume()
        } catch {
            logger.error("Failed to read USDZ file for upload: \(error.localizedDescription)")
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
}
#endif
