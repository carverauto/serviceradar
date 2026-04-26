#if os(iOS)
import Foundation
import SwiftUI
import simd

@available(iOS 16.0, *)
public struct SignalMapView: View {
    public let title: String
    public let points: [WiFiHeatmapPoint]
    public let landmarks: [ManualAPLandmark]
    public let currentPose: SIMD3<Float>?
    public let rfBatchCount: Int?
    public let spectrumBatchCount: Int?
    public let spectrumSummary: SidekickSpectrumSummary?
    public let spectrumSummaries: [SidekickSpectrumSummary]
    public let sidekickStatus: SidekickRelayStatus?
    public let sidekickError: String?
    public let sidekickWarning: String?
    public let rfObservationCount: Int?
    public let rfDecodeError: String?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFloorIndex: Int = 0
    @State private var mapScale: CGFloat = 1.0
    @State private var lastMapScale: CGFloat = 1.0
    @State private var mapOffset: CGSize = .zero
    @State private var lastMapOffset: CGSize = .zero
    @State private var selectedBSSID: String?
    @State private var overlayMode: SignalMapOverlay = .wifiCoverage

    public init(
        title: String,
        points: [WiFiHeatmapPoint],
        landmarks: [ManualAPLandmark],
        currentPose: SIMD3<Float>? = nil,
        rfBatchCount: Int? = nil,
        spectrumBatchCount: Int? = nil,
        spectrumSummary: SidekickSpectrumSummary? = nil,
        spectrumSummaries: [SidekickSpectrumSummary] = [],
        sidekickStatus: SidekickRelayStatus? = nil,
        sidekickError: String? = nil,
        sidekickWarning: String? = nil,
        rfObservationCount: Int? = nil,
        rfDecodeError: String? = nil
    ) {
        self.title = title
        self.points = points
        self.landmarks = landmarks
        self.currentPose = currentPose
        self.rfBatchCount = rfBatchCount
        self.spectrumBatchCount = spectrumBatchCount
        self.spectrumSummary = spectrumSummary
        self.spectrumSummaries = spectrumSummaries
        self.sidekickStatus = sidekickStatus
        self.sidekickError = sidekickError
        self.sidekickWarning = sidekickWarning
        self.rfObservationCount = rfObservationCount
        self.rfDecodeError = rfDecodeError
    }

    public var body: some View {
        VStack(spacing: 12) {
            headerControls
            statusStrip
            failureBanner
            warningBanner
            floorControls
            overlayControls
            apControls
            if let summary = displaySpectrumSummary {
                SpectrumAnalyzerMiniPanel(summary: summary, sweepCount: spectrumBatchCount, compact: false)
            }

            SignalMapCanvas(
                points: Array(visiblePoints.suffix(500)),
                spectrumPoints: Array(visibleSpectrumPoints.suffix(500)),
                landmarks: visibleLandmarks,
                currentPose: visibleCurrentPose,
                overlayMode: overlayMode,
                zoom: mapScale,
                pan: mapOffset
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .center) {
                if mapHasNoVisibleData {
                    VStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 34, weight: .semibold))
                        Text(emptyMapTitle)
                            .font(.headline)
                        Text(emptyMapDetail)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.72))
                            .padding(.horizontal, 28)
                    }
                    .padding(18)
                    .background(Color.black.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        mapOffset = CGSize(
                            width: lastMapOffset.width + value.translation.width,
                            height: lastMapOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastMapOffset = mapOffset
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        mapScale = min(max(lastMapScale * value, 0.75), 8.0)
                    }
                    .onEnded { _ in
                        lastMapScale = mapScale
                    }
            )

            legend
        }
        .padding(12)
        .background(Color(red: 0.025, green: 0.035, blue: 0.05).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var headerControls: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
            Button {
                resetViewport()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)

            Button {
                dismiss()
            } label: {
                Label("Done", systemImage: "xmark")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 14) {
            MetricPill(label: "Heat", value: "\(visiblePoints.count)/\(points.count)")
            MetricPill(label: "APs", value: "\(apSummaries.count)")
            MetricPill(label: "AP Marks", value: "\(landmarks.count)")

            if let rfBatchCount {
                MetricPill(label: "RF Batches", value: "\(rfBatchCount)")
            }

            if let rfObservationCount {
                MetricPill(label: "RF Obs", value: "\(rfObservationCount)")
            }

            if let spectrumBatchCount {
                MetricPill(label: "Spectrum", value: "\(spectrumBatchCount)")
            }

            if let sidekickStatus {
                MetricPill(label: "Sidekick", value: statusLabel(sidekickStatus))
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var overlayControls: some View {
        HStack(spacing: 8) {
            ForEach(SignalMapOverlay.allCases) { mode in
                Button {
                    overlayMode = mode
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .foregroundColor(overlayMode == mode ? .black : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(overlayMode == mode ? Color.cyan : Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var failureBanner: some View {
        if let message = sidekickError ?? failedStatusMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Sidekick failed: \(message)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(10)
            .background(Color.orange.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var warningBanner: some View {
        if failedStatusMessage == nil, sidekickError == nil, let message = rfDecodeError ?? sidekickWarning {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.yellow)
                Text(warningText(for: message))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(10)
            .background(Color.yellow.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var apControls: some View {
        let summaries = apSummaries
        if !summaries.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        selectedBSSID = nil
                        resetViewport()
                    } label: {
                        APFilterChip(
                            title: "All APs",
                            subtitle: "\(floorFilteredPoints.count) pts",
                            rssi: summaries.map(\.strongestRSSI).max(),
                            isSelected: selectedBSSID == nil
                        )
                    }

                    ForEach(summaries.prefix(18)) { summary in
                        Button {
                            selectedBSSID = summary.bssid
                            resetViewport()
                        } label: {
                            APFilterChip(
                                title: summary.displayName,
                                subtitle: "\(summary.count) pts  \(summary.bssidSuffix)",
                                rssi: summary.strongestRSSI,
                                isSelected: selectedBSSID == summary.bssid
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var floorControls: some View {
        let floors = detectedFloors
        if floors.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(floors.enumerated()), id: \.element.id) { index, floor in
                        Button {
                            selectedFloorIndex = index
                            resetViewport()
                        } label: {
                            Text(floor.label)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(index == activeFloorIndex ? .black : .white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(index == activeFloorIndex ? Color.cyan : Color.white.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            switch overlayMode {
            case .wifiCoverage:
                ForEach(SignalLegendStop.allCases) { stop in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(stop.color)
                            .frame(width: 14, height: 14)
                        Text(stop.label)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.82))
                    }
                }
            case .wifiConfidence:
                ForEach(ConfidenceLegendStop.allCases) { stop in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(stop.color)
                            .frame(width: 14, height: 14)
                        Text(stop.label)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.82))
                    }
                }
            case .spectrumInterference:
                ForEach(SpectrumLegendStop.allCases) { stop in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(stop.color)
                            .frame(width: 14, height: 14)
                        Text(stop.label)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.82))
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private func statusLabel(_ status: SidekickRelayStatus) -> String {
        switch status {
        case .idle:
            return "Idle"
        case .connecting:
            return "Connecting"
        case .streaming(let radios, let spectrum):
            return spectrum ? "\(radios) radios + SDR" : "\(radios) radios"
        case .failed:
            return "Failed"
        }
    }

    private func warningText(for message: String) -> String {
        if rfDecodeError != nil {
            return "RF decode warning: \(message)"
        }
        if message.hasPrefix("RF ") {
            return "\(message). Other radios and spectrum capture can continue while this radio reconnects."
        }
        if message.hasPrefix("Backend upload") {
            return "\(message). Local Sidekick heat points keep recording while upload retries in the background."
        }
        return "\(message). Wi-Fi RF capture can continue without spectrum."
    }

    private var detectedFloors: [SignalFloor] {
        SignalFloor.detect(points: points, landmarks: landmarks, currentPose: currentPose)
    }

    private var failedStatusMessage: String? {
        if case .failed(let message) = sidekickStatus {
            return message
        }
        return nil
    }

    private var activeFloorIndex: Int {
        min(max(selectedFloorIndex, 0), max(detectedFloors.count - 1, 0))
    }

    private var activeFloor: SignalFloor? {
        let floors = detectedFloors
        guard !floors.isEmpty else { return nil }
        return floors[activeFloorIndex]
    }

    private var floorFilteredPoints: [WiFiHeatmapPoint] {
        let validPoints = points.filter { $0.position.isValidMapPosition }
        guard let activeFloor else { return validPoints }
        return validPoints.filter { activeFloor.contains(y: $0.y) }
    }

    private var visiblePoints: [WiFiHeatmapPoint] {
        let floorPoints = floorFilteredPoints
        guard let selectedBSSID else { return floorPoints }
        return floorPoints.filter { $0.bssid == selectedBSSID }
    }

    private var visibleSpectrumPoints: [SpectrumHeatmapPoint] {
        guard overlayMode == .spectrumInterference else { return [] }
        return SpectrumHeatmapPoint.build(
            points: Array(visiblePoints.suffix(500)),
            summaries: Array(spectrumSummaries.suffix(160))
        )
    }

    private var displaySpectrumSummary: SidekickSpectrumSummary? {
        guard let spectrumSummary else { return nil }
        var scoresByID: [String: SidekickSpectrumChannelScore] = [:]
        for score in spectrumSummaries.suffix(80).flatMap(\.channelScores) {
            scoresByID[score.id] = score
        }
        for score in spectrumSummary.channelScores {
            scoresByID[score.id] = score
        }

        return SidekickSpectrumSummary(
            sidekickID: spectrumSummary.sidekickID,
            sdrID: spectrumSummary.sdrID,
            deviceKind: spectrumSummary.deviceKind,
            serialNumber: spectrumSummary.serialNumber,
            sweepID: spectrumSummary.sweepID,
            capturedAtUnixNanos: spectrumSummary.capturedAtUnixNanos,
            startFrequencyHz: spectrumSummary.startFrequencyHz,
            stopFrequencyHz: spectrumSummary.stopFrequencyHz,
            binWidthHz: spectrumSummary.binWidthHz,
            sampleCount: spectrumSummary.sampleCount,
            averagePowerDBM: spectrumSummary.averagePowerDBM,
            peakPowerDBM: spectrumSummary.peakPowerDBM,
            peakFrequencyHz: spectrumSummary.peakFrequencyHz,
            sweepRateHz: spectrumSummary.sweepRateHz,
            channelScores: scoresByID.values.sorted { lhs, rhs in
                if lhs.band == rhs.band {
                    return lhs.channel < rhs.channel
                }
                return lhs.band < rhs.band
            }
        )
    }

    private var mapHasNoVisibleData: Bool {
        switch overlayMode {
        case .wifiCoverage, .wifiConfidence:
            return visiblePoints.isEmpty
        case .spectrumInterference:
            return visibleSpectrumPoints.isEmpty
        }
    }

    private var emptyMapTitle: String {
        switch overlayMode {
        case .wifiCoverage, .wifiConfidence:
            if let rfObservationCount, rfObservationCount > 0 {
                return "RF frames decoded, waiting for positioned heat points"
            }
            return "No Sidekick heat points yet"
        case .spectrumInterference:
            if !spectrumSummaries.isEmpty {
                return "Spectrum analyzer running"
            }
            return "Waiting for spectrum heat points"
        }
    }

    private var emptyMapDetail: String {
        switch overlayMode {
        case .wifiCoverage, .wifiConfidence:
            if let rfObservationCount, rfObservationCount > 0 {
                return "Keep LiDAR tracking active and move a few meters so RF samples can attach to survey positions."
            }
            return "Start Sidekick preview or backend streaming, then walk a few meters while LiDAR tracking is active."
        case .spectrumInterference:
            if !spectrumSummaries.isEmpty && visiblePoints.isEmpty {
                return "HackRF summaries are arriving. Wi-Fi heat points are needed before interference can be placed on the map."
            }
            return "Keep walking while LiDAR tracking is active. HackRF summaries are attached to nearby positioned Wi-Fi samples as they arrive."
        }
    }

    private var apSummaries: [SignalAPSummary] {
        SignalAPSummary.summarize(points: floorFilteredPoints)
    }

    private var visibleLandmarks: [ManualAPLandmark] {
        let validLandmarks = landmarks.filter { $0.position.isValidMapPosition }
        guard let activeFloor else { return validLandmarks }
        return validLandmarks.filter { activeFloor.contains(y: $0.y) }
    }

    private var visibleCurrentPose: SIMD3<Float>? {
        guard let currentPose else { return nil }
        guard currentPose.isValidMapPosition else { return nil }
        guard let activeFloor else { return currentPose }
        return activeFloor.contains(y: currentPose.y) ? currentPose : nil
    }

    private func resetViewport() {
        mapScale = 1.0
        lastMapScale = 1.0
        mapOffset = .zero
        lastMapOffset = .zero
    }
}

@available(iOS 16.0, *)
private struct SignalMapCanvas: View {
    let points: [WiFiHeatmapPoint]
    let spectrumPoints: [SpectrumHeatmapPoint]
    let landmarks: [ManualAPLandmark]
    let currentPose: SIMD3<Float>?
    let overlayMode: SignalMapOverlay
    let zoom: CGFloat
    let pan: CGSize

    var body: some View {
        Canvas { context, size in
            let plotRect = CGRect(origin: .zero, size: size)
                .insetBy(dx: 10, dy: 10)

            drawBackground(context: context, rect: plotRect)

            guard let projection = SignalMapProjection(
                points: points,
                landmarks: landmarks,
                currentPose: currentPose,
                rect: plotRect,
                zoom: zoom,
                pan: pan
            ) else {
                return
            }

            drawGrid(context: context, rect: plotRect)
            drawPath(context: context, projection: projection)
            switch overlayMode {
            case .wifiCoverage:
                drawWiFiHeatmap(context: context, projection: projection)
            case .wifiConfidence:
                drawWiFiConfidence(context: context, projection: projection)
            case .spectrumInterference:
                drawSpectrumHeatmap(context: context, projection: projection)
            }
            drawLandmarks(context: context, projection: projection)
            drawCurrentPose(context: context, projection: projection)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    private func drawBackground(context: GraphicsContext, rect: CGRect) {
        context.fill(
            Path(roundedRect: rect, cornerRadius: 8),
            with: .color(Color(red: 0.04, green: 0.055, blue: 0.075))
        )
    }

    private func drawGrid(context: GraphicsContext, rect: CGRect) {
        var path = Path()
        let spacing: CGFloat = 34

        var x = rect.minX
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }

        var y = rect.minY
        while y <= rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }

        context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.6)
    }

    private func drawPath(context: GraphicsContext, projection: SignalMapProjection) {
        let sorted = points.filter { $0.position.isValidMapPosition }.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else { return }

        var path = Path()
        path.move(to: projection.screenPoint(for: sorted[0].position))
        for point in sorted.dropFirst() {
            path.addLine(to: projection.screenPoint(for: point.position))
        }

        context.stroke(path, with: .color(Color.cyan.opacity(0.54)), lineWidth: 2)
    }

    private func drawWiFiHeatmap(context: GraphicsContext, projection: SignalMapProjection) {
        let cellSize = projection.screenSize(widthMeters: 0.75, heightMeters: 0.75)

        for bucket in bucketed(points: points) {
            let center = projection.screenPoint(for: bucket.position)
            let rect = CGRect(
                x: center.x - cellSize.width / 2,
                y: center.y - cellSize.height / 2,
                width: max(cellSize.width, 1),
                height: max(cellSize.height, 1)
            )
            let opacity = min(0.78, 0.42 + Double(bucket.count) * 0.035)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 1.5),
                with: .color(SignalColor.color(for: bucket.rssi).opacity(opacity))
            )

            let radius: CGFloat = 3.5
            let dotRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

            context.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.75)))
            context.stroke(Path(ellipseIn: dotRect), with: .color(SignalColor.color(for: bucket.rssi).opacity(0.95)), lineWidth: 1.4)
        }
    }

    private func drawWiFiConfidence(context: GraphicsContext, projection: SignalMapProjection) {
        let cellSize = projection.screenSize(widthMeters: 0.75, heightMeters: 0.75)

        for bucket in bucketed(points: points) {
            let center = projection.screenPoint(for: bucket.position)
            let rect = CGRect(
                x: center.x - cellSize.width / 2,
                y: center.y - cellSize.height / 2,
                width: max(cellSize.width, 1),
                height: max(cellSize.height, 1)
            )
            let confidence = min(1.0, Double(bucket.count) / 8.0)

            context.fill(
                Path(roundedRect: rect, cornerRadius: 1.5),
                with: .color(ConfidenceColor.color(for: confidence).opacity(0.62))
            )

            let radius: CGFloat = 3.5
            let dotRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.85)))
        }
    }

    private func drawSpectrumHeatmap(context: GraphicsContext, projection: SignalMapProjection) {
        let cellSize = projection.screenSize(widthMeters: 0.8, heightMeters: 0.8)

        for bucket in bucketedSpectrum(points: spectrumPoints) {
            let center = projection.screenPoint(for: bucket.position)
            let rect = CGRect(
                x: center.x - cellSize.width / 2,
                y: center.y - cellSize.height / 2,
                width: max(cellSize.width, 1),
                height: max(cellSize.height, 1)
            )
            let color = SpectrumColor.color(forScore: bucket.score)

            context.fill(
                Path(roundedRect: rect, cornerRadius: 1.5),
                with: .color(color.opacity(0.42 + min(bucket.score, 1.0) * 0.36))
            )
        }
    }

    private func drawLandmarks(context: GraphicsContext, projection: SignalMapProjection) {
        for landmark in landmarks {
            let point = projection.screenPoint(for: landmark.position)
            let pinRect = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
            context.fill(Path(ellipseIn: pinRect), with: .color(.white))
            context.stroke(Path(ellipseIn: pinRect.insetBy(dx: -3, dy: -3)), with: .color(.cyan), lineWidth: 2)

            context.draw(
                Text(landmark.label)
                    .font(.caption2)
                    .foregroundColor(.white),
                at: CGPoint(x: point.x + 10, y: point.y - 12),
                anchor: .leading
            )
        }
    }

    private func drawCurrentPose(context: GraphicsContext, projection: SignalMapProjection) {
        guard let currentPose else { return }
        let point = projection.screenPoint(for: currentPose)
        var marker = Path()
        marker.move(to: CGPoint(x: point.x, y: point.y - 9))
        marker.addLine(to: CGPoint(x: point.x + 8, y: point.y + 8))
        marker.addLine(to: CGPoint(x: point.x - 8, y: point.y + 8))
        marker.closeSubpath()
        context.fill(marker, with: .color(.white))
        context.stroke(marker, with: .color(.black.opacity(0.7)), lineWidth: 1)
    }

    private func bucketed(points: [WiFiHeatmapPoint]) -> [SignalBucket] {
        struct Accumulator {
            var x: Float = 0
            var y: Float = 0
            var z: Float = 0
            var rssi: Double = 0
            var count: Int = 0
        }

        let cellSize: Float = 0.55
        var buckets: [String: Accumulator] = [:]

        for point in points {
            guard point.position.isValidMapPosition,
                  point.rssi.isFinite,
                  let xi = bucketIndex(point.x, cellSize: cellSize),
                  let zi = bucketIndex(point.z, cellSize: cellSize) else {
                continue
            }

            let key = "\(xi):\(zi)"
            var acc = buckets[key] ?? Accumulator()
            acc.x += point.x
            acc.y += point.y
            acc.z += point.z
            acc.rssi += point.rssi
            acc.count += 1
            buckets[key] = acc
        }

        return buckets.values.compactMap { acc in
            guard acc.count > 0 else { return nil }
            let count = Float(acc.count)
            return SignalBucket(
                position: SIMD3<Float>(acc.x / count, acc.y / count, acc.z / count),
                rssi: acc.rssi / Double(acc.count),
                count: acc.count
            )
        }
    }

    private func bucketedSpectrum(points: [SpectrumHeatmapPoint]) -> [SpectrumBucket] {
        struct Accumulator {
            var x: Float = 0
            var y: Float = 0
            var z: Float = 0
            var score: Double = 0
            var count: Int = 0
        }

        let cellSize: Float = 0.55
        var buckets: [String: Accumulator] = [:]

        for point in points {
            guard point.position.isValidMapPosition,
                  point.score.isFinite,
                  let xi = bucketIndex(point.position.x, cellSize: cellSize),
                  let zi = bucketIndex(point.position.z, cellSize: cellSize) else {
                continue
            }

            let key = "\(xi):\(zi)"
            var acc = buckets[key] ?? Accumulator()
            acc.x += point.position.x
            acc.y += point.position.y
            acc.z += point.position.z
            acc.score += point.score
            acc.count += 1
            buckets[key] = acc
        }

        return buckets.values.compactMap { acc in
            guard acc.count > 0 else { return nil }
            let count = Float(acc.count)
            return SpectrumBucket(
                position: SIMD3<Float>(acc.x / count, acc.y / count, acc.z / count),
                score: acc.score / Double(acc.count)
            )
        }
    }

    private func bucketIndex(_ value: Float, cellSize: Float) -> Int? {
        guard value.isFinite, cellSize.isFinite, cellSize > 0 else { return nil }
        let bucket = (value / cellSize).rounded()
        guard bucket.isFinite,
              bucket >= Float(Int.min),
              bucket <= Float(Int.max) else {
            return nil
        }
        return Int(bucket)
    }
}

private struct SignalBucket {
    let position: SIMD3<Float>
    let rssi: Double
    let count: Int
}

private struct SpectrumBucket {
    let position: SIMD3<Float>
    let score: Double
}

private struct SpectrumHeatmapPoint: Identifiable {
    let id = UUID()
    let position: SIMD3<Float>
    let score: Double

    static func build(points: [WiFiHeatmapPoint], summaries: [SidekickSpectrumSummary]) -> [SpectrumHeatmapPoint] {
        guard !points.isEmpty, !summaries.isEmpty else { return [] }
        let sortedSummaries = summaries.sorted { $0.capturedAtUnixNanos < $1.capturedAtUnixNanos }

        return points.compactMap { point in
            guard point.position.isValidMapPosition else { return nil }
            guard let summary = nearestSummary(to: point.timestamp, summaries: sortedSummaries) else { return nil }
            let normalizedScore: Double
            if let score = summary.channelScores.map({ Double($0.interferenceScore) }).max() {
                normalizedScore = score / 100.0
            } else {
                normalizedScore = SpectrumColor.normalizedPower(summary.peakPowerDBM)
            }
            return SpectrumHeatmapPoint(position: point.position, score: min(max(normalizedScore, 0.0), 1.0))
        }
    }

    private static func nearestSummary(
        to timestamp: TimeInterval,
        summaries: [SidekickSpectrumSummary]
    ) -> SidekickSpectrumSummary? {
        guard timestamp.isFinite,
              timestamp >= 0,
              timestamp <= Double(Int64.max) / 1_000_000_000 else {
            return nil
        }

        let targetNanos = Int64(timestamp * 1_000_000_000)
        var best: SidekickSpectrumSummary?
        var bestDelta = Int64.max

        for summary in summaries {
            guard let delta = safeDelta(summary.capturedAtUnixNanos, targetNanos) else { continue }
            if delta < bestDelta {
                best = summary
                bestDelta = delta
            }
        }

        return bestDelta <= 2_500_000_000 ? best : nil
    }

    private static func safeDelta(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let difference = lhs.subtractingReportingOverflow(rhs)
        guard !difference.overflow, difference.partialValue != Int64.min else { return nil }
        return abs(difference.partialValue)
    }
}

private enum SignalMapOverlay: String, CaseIterable, Identifiable {
    case wifiCoverage
    case wifiConfidence
    case spectrumInterference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifiCoverage: return "Wi-Fi RSSI"
        case .wifiConfidence: return "Confidence"
        case .spectrumInterference: return "RF Interference"
        }
    }

    var systemImage: String {
        switch self {
        case .wifiCoverage: return "wifi"
        case .wifiConfidence: return "checkmark.seal"
        case .spectrumInterference: return "waveform.path.ecg"
        }
    }
}

private struct SignalAPSummary: Identifiable {
    let bssid: String
    let ssid: String
    let count: Int
    let strongestRSSI: Double
    let latestTimestamp: TimeInterval

    var id: String { bssid }

    var displayName: String {
        let trimmedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedSSID.isEmpty || trimmedSSID == bssid ? "Hidden" : trimmedSSID
        return String(base.prefix(18))
    }

    var bssidSuffix: String {
        let suffix = bssid.suffix(5)
        return String(suffix)
    }

    static func summarize(points: [WiFiHeatmapPoint]) -> [SignalAPSummary] {
        struct Accumulator {
            var ssid: String = ""
            var count: Int = 0
            var strongestRSSI: Double = -200
            var latestTimestamp: TimeInterval = 0
        }

        var byBSSID: [String: Accumulator] = [:]
        for point in points {
            var acc = byBSSID[point.bssid] ?? Accumulator()
            acc.ssid = point.ssid
            acc.count += 1
            acc.strongestRSSI = max(acc.strongestRSSI, point.rssi)
            acc.latestTimestamp = max(acc.latestTimestamp, point.timestamp)
            byBSSID[point.bssid] = acc
        }

        return byBSSID.map { bssid, acc in
            SignalAPSummary(
                bssid: bssid,
                ssid: acc.ssid,
                count: acc.count,
                strongestRSSI: acc.strongestRSSI,
                latestTimestamp: acc.latestTimestamp
            )
        }
        .sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs.latestTimestamp > rhs.latestTimestamp
            }
            return lhs.count > rhs.count
        }
    }
}

private struct SignalMapProjection {
    let minX: Float
    let maxX: Float
    let minZ: Float
    let maxZ: Float
    let rect: CGRect
    let zoom: CGFloat
    let pan: CGSize

    init?(
        points: [WiFiHeatmapPoint],
        landmarks: [ManualAPLandmark],
        currentPose: SIMD3<Float>?,
        rect: CGRect,
        zoom: CGFloat,
        pan: CGSize
    ) {
        var xs = points.map(\.x).filter(\.isFinite) + landmarks.map(\.x).filter(\.isFinite)
        var zs = points.map(\.z).filter(\.isFinite) + landmarks.map(\.z).filter(\.isFinite)

        if let currentPose, currentPose.isValidMapPosition {
            xs.append(currentPose.x)
            zs.append(currentPose.z)
        }

        guard let minX = xs.min(), let maxX = xs.max(), let minZ = zs.min(), let maxZ = zs.max() else {
            return nil
        }

        let xPadding = max((maxX - minX) * 0.12, 1.0)
        let zPadding = max((maxZ - minZ) * 0.12, 1.0)
        self.minX = minX - xPadding
        self.maxX = maxX + xPadding
        self.minZ = minZ - zPadding
        self.maxZ = maxZ + zPadding
        self.rect = rect
        self.zoom = zoom
        self.pan = pan
    }

    func screenPoint(for position: SIMD3<Float>) -> CGPoint {
        guard position.isValidMapPosition else {
            return CGPoint(x: rect.midX, y: rect.midY)
        }

        let width = max(maxX - minX, 0.01)
        let height = max(maxZ - minZ, 0.01)
        let nx = CGFloat((position.x - minX) / width)
        let nz = CGFloat((position.z - minZ) / height)
        let base = CGPoint(
            x: rect.minX + nx * rect.width,
            y: rect.maxY - nz * rect.height
        )
        return CGPoint(
            x: rect.midX + (base.x - rect.midX) * zoom + pan.width,
            y: rect.midY + (base.y - rect.midY) * zoom + pan.height
        )
    }

    func screenSize(widthMeters: Float, heightMeters: Float) -> CGSize {
        let worldWidth = max(maxX - minX, 0.01)
        let worldHeight = max(maxZ - minZ, 0.01)
        return CGSize(
            width: CGFloat(widthMeters / worldWidth) * rect.width * zoom,
            height: CGFloat(heightMeters / worldHeight) * rect.height * zoom
        )
    }
}

private extension SIMD3 where Scalar == Float {
    var isValidMapPosition: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

private struct SignalFloor: Identifiable {
    let id: Int
    let centerY: Float
    let minY: Float
    let maxY: Float
    let label: String

    func contains(y: Float) -> Bool {
        y >= minY && y <= maxY
    }

    static func detect(
        points: [WiFiHeatmapPoint],
        landmarks: [ManualAPLandmark],
        currentPose: SIMD3<Float>?
    ) -> [SignalFloor] {
        var values = points.map(\.y) + landmarks.map(\.y)
        if let currentPose {
            values.append(currentPose.y)
        }
        values = values.filter { $0.isFinite }.sorted(by: >)
        guard !values.isEmpty else { return [] }

        let splitThreshold: Float = 1.75
        var clusters: [[Float]] = []
        for value in values {
            if let lastIndex = clusters.indices.last,
               let average = average(clusters[lastIndex]),
               abs(value - average) <= splitThreshold {
                clusters[lastIndex].append(value)
            } else {
                clusters.append([value])
            }
        }

        if clusters.count == 1 {
            let all = clusters[0]
            return [SignalFloor(
                id: 0,
                centerY: average(all) ?? 0,
                minY: -Float.greatestFiniteMagnitude,
                maxY: Float.greatestFiniteMagnitude,
                label: "All Floors"
            )]
        }

        return clusters.enumerated().map { index, values in
            let minY = values.min() ?? 0
            let maxY = values.max() ?? 0
            return SignalFloor(
                id: index,
                centerY: average(values) ?? 0,
                minY: minY - splitThreshold / 2.0,
                maxY: maxY + splitThreshold / 2.0,
                label: "Floor \(index + 1)"
            )
        }
    }

    private static func average(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }
}

private enum SignalColor {
    static func normalized(_ rssi: Double) -> Double {
        min(max((rssi + 90.0) / 60.0, 0.0), 1.0)
    }

    static func color(for rssi: Double) -> Color {
        if rssi >= -55.0 {
            return Color(red: 0.16, green: 0.78, blue: 0.46)
        } else if rssi >= -65.0 {
            return Color(red: 0.43, green: 0.86, blue: 0.28)
        } else if rssi >= -75.0 {
            return Color(red: 1.0, green: 0.78, blue: 0.22)
        } else if rssi >= -82.0 {
            return Color(red: 1.0, green: 0.45, blue: 0.20)
        } else {
            return Color(red: 0.95, green: 0.18, blue: 0.24)
        }
    }
}

private enum SignalLegendStop: CaseIterable, Identifiable {
    case excellent
    case good
    case fair
    case poor
    case bad

    var id: Self { self }

    var label: String {
        switch self {
        case .excellent: return "-55+"
        case .good: return "-65"
        case .fair: return "-75"
        case .poor: return "-82"
        case .bad: return "weak"
        }
    }

    var color: Color {
        switch self {
        case .excellent: return SignalColor.color(for: -45)
        case .good: return SignalColor.color(for: -60)
        case .fair: return SignalColor.color(for: -70)
        case .poor: return SignalColor.color(for: -78)
        case .bad: return SignalColor.color(for: -88)
        }
    }
}

private enum ConfidenceColor {
    static func color(for confidence: Double) -> Color {
        if confidence >= 0.78 {
            return Color(red: 0.16, green: 0.78, blue: 0.46)
        } else if confidence >= 0.56 {
            return Color(red: 0.58, green: 0.84, blue: 0.34)
        } else if confidence >= 0.34 {
            return Color(red: 1.0, green: 0.78, blue: 0.22)
        } else if confidence >= 0.18 {
            return Color(red: 1.0, green: 0.45, blue: 0.20)
        } else {
            return Color(red: 0.95, green: 0.18, blue: 0.24)
        }
    }
}

private enum ConfidenceLegendStop: CaseIterable, Identifiable {
    case high
    case good
    case fair
    case low
    case weak

    var id: Self { self }

    var label: String {
        switch self {
        case .high: return "high"
        case .good: return "good"
        case .fair: return "fair"
        case .low: return "low"
        case .weak: return "weak"
        }
    }

    var color: Color {
        switch self {
        case .high: return ConfidenceColor.color(for: 0.9)
        case .good: return ConfidenceColor.color(for: 0.65)
        case .fair: return ConfidenceColor.color(for: 0.45)
        case .low: return ConfidenceColor.color(for: 0.25)
        case .weak: return ConfidenceColor.color(for: 0.05)
        }
    }
}

private enum SpectrumColor {
    static func normalizedPower(_ powerDBM: Float) -> Double {
        guard powerDBM.isFinite else { return 0 }
        return min(max(Double(powerDBM + 95.0) / 45.0, 0.0), 1.0)
    }

    static func color(forScore score: Double) -> Color {
        if score >= 0.78 {
            return Color(red: 0.95, green: 0.18, blue: 0.24)
        } else if score >= 0.58 {
            return Color(red: 1.0, green: 0.45, blue: 0.20)
        } else if score >= 0.38 {
            return Color(red: 1.0, green: 0.78, blue: 0.22)
        } else if score >= 0.18 {
            return Color(red: 0.43, green: 0.86, blue: 0.28)
        } else {
            return Color(red: 0.16, green: 0.62, blue: 0.95)
        }
    }
}

private enum SpectrumLegendStop: CaseIterable, Identifiable {
    case quiet
    case light
    case busy
    case noisy
    case severe

    var id: Self { self }

    var label: String {
        switch self {
        case .quiet: return "quiet"
        case .light: return "light"
        case .busy: return "busy"
        case .noisy: return "noisy"
        case .severe: return "severe"
        }
    }

    var color: Color {
        switch self {
        case .quiet: return SpectrumColor.color(forScore: 0.05)
        case .light: return SpectrumColor.color(forScore: 0.25)
        case .busy: return SpectrumColor.color(forScore: 0.48)
        case .noisy: return SpectrumColor.color(forScore: 0.68)
        case .severe: return SpectrumColor.color(forScore: 0.90)
        }
    }
}

public struct SpectrumAnalyzerMiniPanel: View {
    let summary: SidekickSpectrumSummary
    let sweepCount: Int?
    let compact: Bool

    public init(summary: SidekickSpectrumSummary, sweepCount: Int? = nil, compact: Bool = false) {
        self.summary = summary
        self.sweepCount = sweepCount
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            HStack(spacing: 8) {
                Label("Spectrum", systemImage: "waveform.path.ecg")
                    .font(.system(size: compact ? 11 : 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Text(sweepRateText)
                    .font(.system(size: compact ? 10 : 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
            }

            HStack(spacing: compact ? 8 : 12) {
                SpectrumStat(label: "Peak", value: "\(Int(summary.peakPowerDBM.rounded())) dBm")
                SpectrumStat(label: "Freq", value: String(format: "%.1f MHz", summary.peakFrequencyMHz))
                if !compact {
                    SpectrumStat(label: "Avg", value: "\(Int(summary.averagePowerDBM.rounded())) dBm")
                }
            }

            SpectrumBars(scores: visibleScores, compact: compact)
                .frame(height: compact ? 34 : 52)
        }
        .padding(compact ? 8 : 10)
        .background(Color.black.opacity(compact ? 0.62 : 0.42))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var visibleScores: [SidekickSpectrumChannelScore] {
        let twoGHz = summary.channelScores
            .filter { $0.band == "2.4GHz" }
            .sorted { $0.channel < $1.channel }
        if !twoGHz.isEmpty {
            return compact ? Array(twoGHz.prefix(11)) : twoGHz
        }

        let fiveGHz = summary.channelScores
            .filter { $0.band == "5GHz" }
            .sorted { $0.channel < $1.channel }
        return compact ? Array(fiveGHz.prefix(12)) : Array(fiveGHz.prefix(18))
    }

    private var sweepRateText: String {
        if let rate = summary.sweepRateHz, rate.isFinite, rate > 0 {
            return String(format: "%.1f/s", rate)
        }
        if let sweepCount {
            return "\(sweepCount) sweeps"
        }
        return "warming"
    }
}

private struct SpectrumStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.48))
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpectrumBars: View {
    let scores: [SidekickSpectrumChannelScore]
    let compact: Bool

    var body: some View {
        GeometryReader { geometry in
            let barWidth = max((geometry.size.width - CGFloat(max(scores.count - 1, 0)) * 3) / CGFloat(max(scores.count, 1)), 3)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(scores) { score in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(SpectrumColor.color(forScore: Double(score.interferenceScore) / 100.0))
                            .frame(
                                width: barWidth,
                                height: max(
                                    4,
                                    (geometry.size.height - CGFloat(compact ? 10 : 14))
                                        * CGFloat(score.interferenceScore) / 100.0
                                )
                            )
                        if !compact {
                            Text("\(score.channel)")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.55))
                                .frame(width: barWidth * 1.4)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

private struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.54))
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct APFilterChip: View {
    let title: String
    let subtitle: String
    let rssi: Double?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(SignalColor.color(for: rssi ?? -90))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(isSelected ? .black : .white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(isSelected ? .black.opacity(0.62) : .white.opacity(0.58))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minWidth: 86, alignment: .leading)
        .background(isSelected ? Color.cyan : Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
#endif
