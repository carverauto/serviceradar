import Foundation
import RoomPlan
import os.log

/// Manages the RoomPlan LiDAR scanning session to build a physical 3D mesh
/// of the environment while walking the survey.
@available(iOS 16.0, *)
public class RoomScanner: ObservableObject, RoomCaptureViewDelegate {
    @Published public var isScanning = false
    @Published public var finalResult: CapturedRoom? = nil
    
    // We act as the delegate for the RoomCaptureView wrapped in our SwiftUI view.
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
}
