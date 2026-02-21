import Foundation
import RoomPlan
import os.log

/// Manages the RoomPlan LiDAR scanning session to build a physical 3D mesh
/// of the environment while walking the survey.
@available(iOS 16.0, *)
public class RoomScanner: ObservableObject, RoomCaptureViewDelegate {
    @Published public var isScanning = false
    @Published public var finalResult: CapturedRoom? = nil
    
    // In a full SwiftUI app, we would wrap RoomCaptureView in UIViewRepresentable
    // For this business logic manager, we handle the delegates.
    private let logger = Logger(subsystem: "com.serviceradar.fieldsurvey", category: "RoomScanner")
    
    public init() {}
    
    public func startSession(in view: RoomCaptureView) {
        view.delegate = self
        
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
    
    // MARK: - RoomCaptureViewDelegate
    
    public func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error = error {
            logger.error("Capture processing error: \(error.localizedDescription)")
            return false
        }
        return true
    }
    
    public func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error = error {
            logger.error("Final processing error: \(error.localizedDescription)")
            return
        }
        
        // This CapturedRoom contains walls, doors, windows, and objects.
        // In the pipeline, this USDZ / geometry data is saved and uploaded
        // along with the Arrow IPC RF samples for the God-View backend.
        DispatchQueue.main.async {
            self.finalResult = processedResult
            self.logger.info("Room scan completed. Captured \(processedResult.walls.count) walls and \(processedResult.objects.count) objects.")
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
}
