import Foundation

public struct FieldSurveyRoomArtifactUploadResult: Decodable, Sendable {
    public let ok: Bool
    public let artifactId: String?
    public let sessionId: String?
    public let artifactType: String?
    public let contentType: String?
    public let objectKey: String?
    public let byteSize: Int?
    public let sha256: String?
    public let uploadedAt: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case artifactId = "artifact_id"
        case sessionId = "session_id"
        case artifactType = "artifact_type"
        case contentType = "content_type"
        case objectKey = "object_key"
        case byteSize = "byte_size"
        case sha256
        case uploadedAt = "uploaded_at"
    }
}

public struct FieldSurveyRoomArtifactUploader: Sendable {
    public init() {}

    public func uploadRoomPlanUSDZ(
        fileURL: URL,
        baseURL: String,
        authToken: String,
        sessionID: String,
        capturedAt: Date = Date()
    ) async throws -> FieldSurveyRoomArtifactUploadResult {
        try await uploadArtifact(
            fileURL: fileURL,
            baseURL: baseURL,
            authToken: authToken,
            sessionID: sessionID,
            artifactType: "roomplan_usdz",
            contentType: "model/vnd.usdz+zip",
            capturedAt: capturedAt
        )
    }

    public func uploadFloorplanGeoJSON(
        fileURL: URL,
        baseURL: String,
        authToken: String,
        sessionID: String,
        capturedAt: Date = Date()
    ) async throws -> FieldSurveyRoomArtifactUploadResult {
        try await uploadArtifact(
            fileURL: fileURL,
            baseURL: baseURL,
            authToken: authToken,
            sessionID: sessionID,
            artifactType: "floorplan_geojson",
            contentType: "application/geo+json",
            capturedAt: capturedAt
        )
    }

    public func uploadPointCloudPLY(
        fileURL: URL,
        baseURL: String,
        authToken: String,
        sessionID: String,
        capturedAt: Date = Date()
    ) async throws -> FieldSurveyRoomArtifactUploadResult {
        try await uploadArtifact(
            fileURL: fileURL,
            baseURL: baseURL,
            authToken: authToken,
            sessionID: sessionID,
            artifactType: "point_cloud_ply",
            contentType: "application/octet-stream",
            capturedAt: capturedAt
        )
    }

    public func uploadArtifact(
        fileURL: URL,
        baseURL: String,
        authToken: String,
        sessionID: String,
        artifactType: String,
        contentType: String,
        capturedAt: Date = Date()
    ) async throws -> FieldSurveyRoomArtifactUploadResult {
        let trimmedAuthToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAuthToken.isEmpty, trimmedAuthToken != "OFFLINE_MODE" else {
            throw URLError(.userAuthenticationRequired)
        }

        guard let url = roomArtifactURL(baseURL: baseURL, sessionID: sessionID, artifactType: artifactType) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(trimmedAuthToken)", forHTTPHeaderField: "Authorization")
        request.setValue(artifactType, forHTTPHeaderField: "X-FieldSurvey-Artifact-Type")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(Self.unixNanos(from: capturedAt)), forHTTPHeaderField: "X-FieldSurvey-Captured-At-Unix-Nanos")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw NSError(
                domain: "FieldSurveyRoomArtifactUploader",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }

        return try JSONDecoder().decode(FieldSurveyRoomArtifactUploadResult.self, from: data)
    }

    private func roomArtifactURL(baseURL: String, sessionID: String, artifactType: String) -> URL? {
        let trimmedBaseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !trimmedBaseURL.isEmpty else { return nil }

        var pathSegmentAllowed = CharacterSet.urlPathAllowed
        pathSegmentAllowed.remove(charactersIn: "/")
        let encodedSessionID = sessionID.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? sessionID
        guard var components = URLComponents(string: "\(trimmedBaseURL)/v1/field-survey/\(encodedSessionID)/room-artifacts") else {
            return nil
        }

        components.queryItems = [URLQueryItem(name: "artifact_type", value: artifactType)]
        return components.url
    }

    private static func unixNanos(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
    }
}
