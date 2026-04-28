#if os(iOS)
import Foundation
import Combine
import MetalKit
import SwiftUI
import simd

@available(iOS 16.0, *)
public struct SignalMapView: View {
    public let title: String
    public let points: [WiFiHeatmapPoint]
    public let landmarks: [ManualAPLandmark]
    public let floorplanSegments: [SurveyFloorplanSegment]
    public let currentPose: SIMD3<Float>?
    public let rfBatchCount: Int?
    public let spectrumBatchCount: Int?
    public let spectrumSummary: SidekickSpectrumSummary?
    public let spectrumSummaries: [SidekickSpectrumSummary]
    public let adaptiveScan: SidekickAdaptiveScanSnapshot?
    public let sidekickStatus: SidekickRelayStatus?
    public let sidekickError: String?
    public let sidekickWarning: String?
    public let backendFrameCount: Int?
    public let rfObservationCount: Int?
    public let rfDecodeError: String?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFloorIndex: Int = 0
    @State private var mapScale: CGFloat = 1.0
    @State private var lastMapScale: CGFloat = 1.0
    @State private var mapOffset: CGSize = .zero
    @State private var lastMapOffset: CGSize = .zero
    @State private var selectedBSSID: String?
    @StateObject private var coverageStore = SignalCoverageRenderStore()

    public init(
        title: String,
        points: [WiFiHeatmapPoint],
        landmarks: [ManualAPLandmark],
        floorplanSegments: [SurveyFloorplanSegment] = [],
        currentPose: SIMD3<Float>? = nil,
        rfBatchCount: Int? = nil,
        spectrumBatchCount: Int? = nil,
        spectrumSummary: SidekickSpectrumSummary? = nil,
        spectrumSummaries: [SidekickSpectrumSummary] = [],
        adaptiveScan: SidekickAdaptiveScanSnapshot? = nil,
        sidekickStatus: SidekickRelayStatus? = nil,
        sidekickError: String? = nil,
        sidekickWarning: String? = nil,
        backendFrameCount: Int? = nil,
        rfObservationCount: Int? = nil,
        rfDecodeError: String? = nil
    ) {
        self.title = title
        self.points = points
        self.landmarks = landmarks
        self.floorplanSegments = floorplanSegments
        self.currentPose = currentPose
        self.rfBatchCount = rfBatchCount
        self.spectrumBatchCount = spectrumBatchCount
        self.spectrumSummary = spectrumSummary
        self.spectrumSummaries = spectrumSummaries
        self.adaptiveScan = adaptiveScan
        self.sidekickStatus = sidekickStatus
        self.sidekickError = sidekickError
        self.sidekickWarning = sidekickWarning
        self.backendFrameCount = backendFrameCount
        self.rfObservationCount = rfObservationCount
        self.rfDecodeError = rfDecodeError
    }

    public var body: some View {
        let renderState = makeRenderState()
        let renderPoints = renderState.visiblePoints
        let summaries = renderState.apSummaries
        let signalBuckets = SignalBucket.build(from: renderPoints)
        let coverageSignature = SignalCoverageRenderSignature(
            points: renderPoints,
            floorplanSegments: renderState.floorplanSegments
        )

        VStack(spacing: 12) {
            headerControls
            statusStrip(visiblePointCount: renderPoints.count, apCount: summaries.count)
            failureBanner
            warningBanner
            floorControls(floors: renderState.floors, activeIndex: renderState.activeFloorIndex)
            apControls(summaries: summaries, floorPointCount: renderState.floorPoints.count)
            if let summary = displaySpectrumSummary {
                SpectrumAnalyzerMiniPanel(
                    summary: summary,
                    summaries: spectrumSummaries,
                    sweepCount: spectrumBatchCount,
                    compact: false
                )
            }

            SignalMapCanvas(
                signalBuckets: signalBuckets,
                landmarks: renderState.visibleLandmarks,
                floorplanSegments: renderState.floorplanSegments,
                currentPose: renderState.visibleCurrentPose,
                predictions: coverageStore.predictions,
                zoom: mapScale,
                pan: mapOffset
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .center) {
                if renderPoints.isEmpty {
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
        .onAppear {
            coverageStore.update(points: renderPoints, signature: coverageSignature)
        }
        .onChange(of: coverageSignature) { _, newSignature in
            coverageStore.update(points: renderPoints, signature: newSignature)
        }
        .onDisappear {
            coverageStore.cancel()
        }
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
                coverageStore.cancel()
                dismiss()
            } label: {
                Label("Done", systemImage: "xmark")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func statusStrip(visiblePointCount: Int, apCount: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MetricPill(label: "Heat", value: "\(visiblePointCount)/\(points.count)")
                MetricPill(label: "APs", value: "\(apCount)")
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

                if let adaptiveScan {
                    MetricPill(label: "Scan", value: adaptiveScanLabel(adaptiveScan))
                }

                if let backendFrameCount {
                    MetricPill(label: "Backend", value: backendFrameCount > 0 ? "\(backendFrameCount) frames" : "pending")
                }
            }
            .padding(.horizontal, 1)
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adaptiveScanLabel(_ snapshot: SidekickAdaptiveScanSnapshot) -> String {
        let topChannels = snapshot.channels
            .filter { $0.observed != false }
            .prefix(3)
            .map { channel in
                channel.channel.map { "ch\($0)" } ?? "\(channel.frequencyMHz)"
            }
            .joined(separator: "/")
        let observedChannels = snapshot.channels.filter { $0.observed == true }.count

        if topChannels.isEmpty {
            return "\(snapshot.observedBSSIDCount) APs • \(observedChannels)/\(snapshot.channelCount) ch"
        }
        return "\(topChannels) • \(observedChannels)/\(snapshot.channelCount) ch"
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
    private func apControls(summaries: [SignalAPSummary], floorPointCount: Int) -> some View {
        if !summaries.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        selectedBSSID = nil
                        resetViewport()
                    } label: {
                        APFilterChip(
                            title: "All APs",
                            subtitle: "\(floorPointCount) pts",
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
    private func floorControls(floors: [SignalFloor], activeIndex: Int) -> some View {
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
                                .foregroundColor(index == activeIndex ? .black : .white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(index == activeIndex ? Color.cyan : Color.white.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
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
        visiblePoints.isEmpty
    }

    private var emptyMapTitle: String {
        if let rfObservationCount, rfObservationCount > 0 {
            return "RF frames decoded, waiting for positioned heat points"
        }
        return "No Sidekick heat points yet"
    }

    private var emptyMapDetail: String {
        if let rfObservationCount, rfObservationCount > 0 {
            return "Keep LiDAR tracking active and move a few meters so RF samples can attach to survey positions."
        }
        return "Start Sidekick preview or backend streaming, then walk a few meters while LiDAR tracking is active."
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

    private func makeRenderState() -> SignalMapRenderState {
        let floors = SignalFloor.detect(points: points, landmarks: landmarks, currentPose: currentPose)
        let activeIndex = min(max(selectedFloorIndex, 0), max(floors.count - 1, 0))
        let floor = floors.isEmpty ? nil : floors[activeIndex]

        let validPoints = points.filter { $0.position.isValidMapPosition }
        let floorPoints = floor.map { activeFloor in
            validPoints.filter { activeFloor.contains(y: $0.y) }
        } ?? validPoints
        let visiblePoints = selectedBSSID.map { bssid in
            floorPoints.filter { $0.bssid == bssid }
        } ?? floorPoints

        let validLandmarks = landmarks.filter { $0.position.isValidMapPosition }
        let visibleLandmarks = floor.map { activeFloor in
            validLandmarks.filter { activeFloor.contains(y: $0.y) }
        } ?? validLandmarks

        let visibleCurrentPose: SIMD3<Float>?
        if let currentPose, currentPose.isValidMapPosition {
            if let floor {
                visibleCurrentPose = floor.contains(y: currentPose.y) ? currentPose : nil
            } else {
                visibleCurrentPose = currentPose
            }
        } else {
            visibleCurrentPose = nil
        }

        return SignalMapRenderState(
            floors: floors,
            activeFloorIndex: activeIndex,
            floorPoints: floorPoints,
            visiblePoints: visiblePoints,
            visibleLandmarks: visibleLandmarks,
            floorplanSegments: floorplanSegments,
            visibleCurrentPose: visibleCurrentPose,
            apSummaries: SignalAPSummary.summarize(points: floorPoints)
        )
    }
}

private struct SignalMapRenderState {
    let floors: [SignalFloor]
    let activeFloorIndex: Int
    let floorPoints: [WiFiHeatmapPoint]
    let visiblePoints: [WiFiHeatmapPoint]
    let visibleLandmarks: [ManualAPLandmark]
    let floorplanSegments: [SurveyFloorplanSegment]
    let visibleCurrentPose: SIMD3<Float>?
    let apSummaries: [SignalAPSummary]
}

private struct SignalCoverageRenderSignature: Equatable, Sendable {
    let count: Int
    let latestTimestampBucket: Int
    let minX: Float
    let maxX: Float
    let minZ: Float
    let maxZ: Float

    init(points: [WiFiHeatmapPoint], floorplanSegments: [SurveyFloorplanSegment]) {
        let validPoints = points.filter { $0.position.isValidMapPosition && $0.rssi.isFinite }
        count = validPoints.count
        latestTimestampBucket = Int(((validPoints.map(\.timestamp).max() ?? 0) * 2).rounded())

        let xs = validPoints.map(\.x).filter(\.isFinite)
            + floorplanSegments.flatMap { [$0.start.x, $0.end.x] }.filter(\.isFinite)
        let zs = validPoints.map(\.z).filter(\.isFinite)
            + floorplanSegments.flatMap { [$0.start.y, $0.end.y] }.filter(\.isFinite)
        guard let rawMinX = xs.min(),
              let rawMaxX = xs.max(),
              let rawMinZ = zs.min(),
              let rawMaxZ = zs.max() else {
            minX = 0
            maxX = 0
            minZ = 0
            maxZ = 0
            return
        }

        let xPadding = max((rawMaxX - rawMinX) * 0.12, 1.0)
        let zPadding = max((rawMaxZ - rawMinZ) * 0.12, 1.0)
        minX = SignalCoverageRenderSignature.rounded(rawMinX - xPadding)
        maxX = SignalCoverageRenderSignature.rounded(rawMaxX + xPadding)
        minZ = SignalCoverageRenderSignature.rounded(rawMinZ - zPadding)
        maxZ = SignalCoverageRenderSignature.rounded(rawMaxZ + zPadding)
    }

    var canInterpolate: Bool {
        count >= 3 && maxX > minX && maxZ > minZ
    }

    private static func rounded(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return (value * 10).rounded() / 10
    }
}

@MainActor
private final class SignalCoverageRenderStore: ObservableObject {
    @Published private(set) var predictions: [SignalCoveragePrediction] = []

    private var currentSignature: SignalCoverageRenderSignature?
    private var task: Task<Void, Never>?

    func update(points: [WiFiHeatmapPoint], signature: SignalCoverageRenderSignature) {
        guard signature != currentSignature else { return }
        currentSignature = signature
        task?.cancel()

        guard signature.canInterpolate else {
            predictions = []
            return
        }

        let capturedPoints = Array(points.suffix(1_200))

        task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            let predictedCoverage = SignalCoverageInterpolator.coverageGrid(
                points: capturedPoints,
                minX: signature.minX,
                maxX: signature.maxX,
                minZ: signature.minZ,
                maxZ: signature.maxZ,
                preferredCellSize: 0.38
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.currentSignature == signature else { return }
                self?.predictions = predictedCoverage
                self?.task = nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        predictions = []
    }
}

@available(iOS 16.0, *)
private struct SignalMapCanvas: View {
    let signalBuckets: [SignalBucket]
    let landmarks: [ManualAPLandmark]
    let floorplanSegments: [SurveyFloorplanSegment]
    let currentPose: SIMD3<Float>?
    let predictions: [SignalCoveragePrediction]
    let zoom: CGFloat
    let pan: CGSize

    var body: some View {
        ZStack {
            Canvas { context, size in
                let plotRect = CGRect(origin: .zero, size: size)
                    .insetBy(dx: 10, dy: 10)

                drawBackground(context: context, rect: plotRect)

                guard let projection = SignalMapProjection(
                    signalBuckets: signalBuckets,
                    landmarks: landmarks,
                    floorplanSegments: floorplanSegments,
                    currentPose: currentPose,
                    rect: plotRect,
                    zoom: zoom,
                    pan: pan
                ) else {
                    return
                }

                drawGrid(context: context, rect: plotRect)
                drawFloorplan(context: context, projection: projection)
            }

            if !predictions.isEmpty {
                MetalSignalHeatmapView(
                    predictions: predictions,
                    signalBuckets: signalBuckets,
                    landmarks: landmarks,
                    floorplanSegments: floorplanSegments,
                    currentPose: currentPose,
                    zoom: zoom,
                    pan: pan
                )
            }

            Canvas { context, size in
                let plotRect = CGRect(origin: .zero, size: size)
                    .insetBy(dx: 10, dy: 10)

                guard let projection = SignalMapProjection(
                    signalBuckets: signalBuckets,
                    landmarks: landmarks,
                    floorplanSegments: floorplanSegments,
                    currentPose: currentPose,
                    rect: plotRect,
                    zoom: zoom,
                    pan: pan
                ) else {
                    return
                }

                drawMeasuredBuckets(
                    context: context,
                    projection: projection,
                    buckets: signalBuckets,
                    opacityScale: predictions.isEmpty ? 1.0 : 0.62
                )
                drawLandmarks(context: context, projection: projection)
                drawCurrentPose(context: context, projection: projection)
            }
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

    private func drawFloorplan(context: GraphicsContext, projection: SignalMapProjection) {
        guard !floorplanSegments.isEmpty else { return }

        var wallPath = Path()
        var openingPath = Path()

        for segment in floorplanSegments {
            let start = projection.screenPoint(for: segment.start)
            let end = projection.screenPoint(for: segment.end)

            if segment.kind == "wall" {
                wallPath.move(to: start)
                wallPath.addLine(to: end)
            } else {
                openingPath.move(to: start)
                openingPath.addLine(to: end)
            }
        }

        context.stroke(wallPath, with: .color(Color.cyan.opacity(0.62)), lineWidth: max(1.2, 2.4 * projection.zoom))
        context.stroke(openingPath, with: .color(Color.white.opacity(0.72)), lineWidth: max(1.0, 1.8 * projection.zoom))
    }

    private func drawMeasuredBuckets(
        context: GraphicsContext,
        projection: SignalMapProjection,
        buckets: [SignalBucket],
        opacityScale: Double = 1.0
    ) {
        let baseSize = projection.screenSize(widthMeters: 0.7, heightMeters: 0.7)

        for bucket in buckets {
            let center = projection.screenPoint(for: bucket.position)
            let strength = SignalColor.normalized(bucket.rssi)
            let density = min(Double(bucket.count), 8.0) / 8.0
            let radiusScale = 0.34 + CGFloat(strength) * 0.24 + CGFloat(density) * 0.08
            let radius = min(
                max(max(baseSize.width, baseSize.height) * radiusScale, 7),
                30
            )
            let circle = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let opacity = (0.18 + strength * 0.46 + density * 0.10) * opacityScale
            context.fill(
                Path(ellipseIn: circle),
                with: .color(SignalColor.color(for: bucket.rssi).opacity(opacity))
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
}

private struct SignalBucket {
    let position: SIMD3<Float>
    let rssi: Double
    let count: Int

    static func build(from points: [WiFiHeatmapPoint]) -> [SignalBucket] {
        struct Accumulator {
            var x: Float = 0
            var y: Float = 0
            var z: Float = 0
            var strongestRSSI: Double = -200
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
            acc.strongestRSSI = max(acc.strongestRSSI, point.rssi)
            acc.count += 1
            buckets[key] = acc
        }

        return buckets.values.compactMap { acc in
            guard acc.count > 0 else { return nil }
            let count = Float(acc.count)
            return SignalBucket(
                position: SIMD3<Float>(acc.x / count, acc.y / count, acc.z / count),
                rssi: acc.strongestRSSI,
                count: acc.count
            )
        }
    }

    private static func bucketIndex(_ value: Float, cellSize: Float) -> Int? {
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

@available(iOS 16.0, *)
private struct MetalSignalHeatmapView: UIViewRepresentable {
    let predictions: [SignalCoveragePrediction]
    let signalBuckets: [SignalBucket]
    let landmarks: [ManualAPLandmark]
    let floorplanSegments: [SurveyFloorplanSegment]
    let currentPose: SIMD3<Float>?
    let zoom: CGFloat
    let pan: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = MTKView(frame: .zero, device: device)
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.isOpaque = false
        view.isPaused = true
        view.preferredFramesPerSecond = 30

        if let device,
           let renderer = MetalSignalHeatmapRenderer(device: device) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }

        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.update(
            predictions: predictions,
            signalBuckets: signalBuckets,
            landmarks: landmarks,
            floorplanSegments: floorplanSegments,
            currentPose: currentPose,
            zoom: zoom,
            pan: pan,
            size: view.bounds.size
        )
        view.setNeedsDisplay()
    }

    final class Coordinator {
        var renderer: MetalSignalHeatmapRenderer?
    }
}

private struct MetalHeatmapSample {
    let center: SIMD2<Float>
    let radius: Float
    let alpha: Float
    let color: SIMD4<Float>
}

private struct MetalHeatmapUniforms {
    let viewport: SIMD2<Float>
}

private final class MetalSignalHeatmapRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let lock = NSLock()
    private var samples: [MetalHeatmapSample] = []
    private var viewport = SIMD2<Float>(1, 1)

    init?(device: MTLDevice) {
        self.device = device
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "heatmapVertex"),
              let fragmentFunction = library.makeFunction(name: "heatmapFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        super.init()
    }

    func update(
        predictions: [SignalCoveragePrediction],
        signalBuckets: [SignalBucket],
        landmarks: [ManualAPLandmark],
        floorplanSegments: [SurveyFloorplanSegment],
        currentPose: SIMD3<Float>?,
        zoom: CGFloat,
        pan: CGSize,
        size: CGSize
    ) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)
        guard size.width > 1,
              size.height > 1,
              let projection = SignalMapProjection(
                signalBuckets: signalBuckets,
                landmarks: landmarks,
                floorplanSegments: floorplanSegments,
                currentPose: currentPose,
                rect: rect,
                zoom: zoom,
                pan: pan
              ) else {
            setSamples([], viewport: SIMD2<Float>(Float(max(size.width, 1)), Float(max(size.height, 1))))
            return
        }

        let baseSize = projection.screenSize(widthMeters: 0.55, heightMeters: 0.55)
        let mapDiagonalMeters = hypot(projection.maxX - projection.minX, projection.maxZ - projection.minZ)
        let maxPredictionDistanceMeters: Float
        switch signalBuckets.count {
        case 0..<12:
            maxPredictionDistanceMeters = min(max(mapDiagonalMeters * 0.35, 4.0), 8.0)
        case 12..<30:
            maxPredictionDistanceMeters = min(max(mapDiagonalMeters * 0.45, 6.0), 12.0)
        default:
            maxPredictionDistanceMeters = min(max(mapDiagonalMeters * 0.65, 9.0), 18.0)
        }

        let heatSamples = predictions
            .filter {
                $0.nearestSampleDistance <= maxPredictionDistanceMeters
            }
            .prefix(3_600)
            .map { prediction -> MetalHeatmapSample in
                let center = projection.screenPoint(for: prediction.position)
                let radius = min(max(max(baseSize.width, baseSize.height) * 1.18, 9), 42)
                let distanceFade = max(0, 1 - prediction.nearestSampleDistance / maxPredictionDistanceMeters)
                let confidence = Float(min(max(prediction.confidence, 0.0), 1.0))
                let strength = Float(SignalColor.normalized(prediction.rssi))
                let alpha = (0.08 + strength * 0.24 + confidence * 0.16) * max(distanceFade, 0.32)
                let color = SignalColor.rgba(for: prediction.rssi)
                return MetalHeatmapSample(
                    center: SIMD2<Float>(Float(center.x), Float(center.y)),
                    radius: Float(radius),
                    alpha: alpha,
                    color: color
                )
            }

        setSamples(Array(heatSamples), viewport: SIMD2<Float>(Float(size.width), Float(size.height)))
    }

    func draw(in view: MTKView) {
        lock.lock()
        let drawSamples = samples
        let drawViewport = viewport
        lock.unlock()

        guard !drawSamples.isEmpty,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        var uniforms = MetalHeatmapUniforms(viewport: drawViewport)
        encoder.setRenderPipelineState(pipelineState)
        drawSamples.withUnsafeBytes { sampleBuffer in
            guard let sampleBaseAddress = sampleBuffer.baseAddress else { return }
            encoder.setVertexBytes(sampleBaseAddress, length: sampleBuffer.count, index: 0)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<MetalHeatmapUniforms>.stride,
                index: 1
            )
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: drawSamples.count)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lock.lock()
        let currentSamples = samples
        lock.unlock()
        setSamples(currentSamples, viewport: SIMD2<Float>(Float(max(size.width, 1)), Float(max(size.height, 1))))
    }

    private func setSamples(_ newSamples: [MetalHeatmapSample], viewport newViewport: SIMD2<Float>) {
        lock.lock()
        samples = newSamples
        viewport = newViewport
        lock.unlock()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct HeatmapSample {
        float2 center;
        float radius;
        float alpha;
        float4 color;
    };

    struct HeatmapUniforms {
        float2 viewport;
    };

    struct HeatmapVertexOut {
        float4 position [[position]];
        float2 pixel;
        float2 center;
        float radius;
        float alpha;
        float4 color;
    };

    vertex HeatmapVertexOut heatmapVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant HeatmapSample *samples [[buffer(0)]],
        constant HeatmapUniforms &uniforms [[buffer(1)]]
    ) {
        constexpr float2 corners[6] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0, -1.0),
            float2( 1.0,  1.0),
            float2(-1.0,  1.0)
        };

        HeatmapSample sample = samples[instanceID];
        float2 pixel = sample.center + corners[vertexID] * sample.radius;
        float2 clip = float2(
            (pixel.x / max(uniforms.viewport.x, 1.0)) * 2.0 - 1.0,
            1.0 - (pixel.y / max(uniforms.viewport.y, 1.0)) * 2.0
        );

        HeatmapVertexOut out;
        out.position = float4(clip, 0.0, 1.0);
        out.pixel = pixel;
        out.center = sample.center;
        out.radius = sample.radius;
        out.alpha = sample.alpha;
        out.color = sample.color;
        return out;
    }

    fragment float4 heatmapFragment(HeatmapVertexOut in [[stage_in]]) {
        float distanceFromCenter = distance(in.pixel, in.center);
        float normalized = saturate(1.0 - distanceFromCenter / max(in.radius, 1.0));
        float falloff = smoothstep(0.0, 0.72, normalized);
        float alpha = in.alpha * falloff;
        return float4(in.color.rgb, alpha);
    }
    """
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
        signalBuckets: [SignalBucket],
        landmarks: [ManualAPLandmark],
        floorplanSegments: [SurveyFloorplanSegment],
        currentPose: SIMD3<Float>?,
        rect: CGRect,
        zoom: CGFloat,
        pan: CGSize
    ) {
        var xs = signalBuckets.map { $0.position.x }.filter(\.isFinite) + landmarks.map(\.x).filter(\.isFinite)
        var zs = signalBuckets.map { $0.position.z }.filter(\.isFinite) + landmarks.map(\.z).filter(\.isFinite)
        xs += floorplanSegments.flatMap { [$0.start.x, $0.end.x] }.filter(\.isFinite)
        zs += floorplanSegments.flatMap { [$0.start.y, $0.end.y] }.filter(\.isFinite)

        if xs.isEmpty, let currentPose, currentPose.isValidMapPosition {
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

    func screenPoint(for position: SIMD2<Float>) -> CGPoint {
        let width = max(maxX - minX, 0.01)
        let height = max(maxZ - minZ, 0.01)
        let nx = CGFloat((position.x - minX) / width)
        let nz = CGFloat((position.y - minZ) / height)
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

    static func rgba(for rssi: Double) -> SIMD4<Float> {
        if rssi >= -55.0 {
            return SIMD4<Float>(0.16, 0.78, 0.46, 1.0)
        } else if rssi >= -65.0 {
            return SIMD4<Float>(0.43, 0.86, 0.28, 1.0)
        } else if rssi >= -75.0 {
            return SIMD4<Float>(1.0, 0.78, 0.22, 1.0)
        } else if rssi >= -82.0 {
            return SIMD4<Float>(1.0, 0.45, 0.20, 1.0)
        } else {
            return SIMD4<Float>(0.95, 0.18, 0.24, 1.0)
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

public struct SpectrumAnalyzerMiniPanel: View {
    let summary: SidekickSpectrumSummary
    let summaries: [SidekickSpectrumSummary]
    let sweepCount: Int?
    let compact: Bool

    public init(
        summary: SidekickSpectrumSummary,
        summaries: [SidekickSpectrumSummary] = [],
        sweepCount: Int? = nil,
        compact: Bool = false
    ) {
        self.summary = summary
        self.summaries = summaries
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

            if !compact {
                SpectrumWaterfall(summaries: waterfallSummaries)
                    .frame(height: 74)
            }
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

    private var waterfallSummaries: [SidekickSpectrumSummary] {
        let source = summaries.isEmpty ? [summary] : summaries
        return Array(source.suffix(48))
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

private struct SpectrumWaterfall: View {
    let summaries: [SidekickSpectrumSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Canvas { context, size in
                let channelIDs = visibleChannelIDs
                guard !summaries.isEmpty, !channelIDs.isEmpty else { return }

                let rowHeight = max(size.height / CGFloat(summaries.count), 1)
                let columnWidth = max(size.width / CGFloat(channelIDs.count), 1)

                for (rowIndex, summary) in summaries.enumerated() {
                    let scores = Dictionary(uniqueKeysWithValues: summary.channelScores.map { ($0.id, $0) })
                    let y = size.height - CGFloat(rowIndex + 1) * rowHeight

                    for (columnIndex, channelID) in channelIDs.enumerated() {
                        guard let score = scores[channelID] else { continue }
                        let strength = Double(score.interferenceScore) / 100.0
                        let rect = CGRect(
                            x: CGFloat(columnIndex) * columnWidth,
                            y: y,
                            width: max(columnWidth - 0.5, 0.5),
                            height: max(rowHeight - 0.5, 0.5)
                        )
                        context.fill(
                            Path(rect),
                            with: .color(SpectrumColor.color(forScore: strength).opacity(0.86))
                        )
                    }
                }
            }
            .background(Color.black.opacity(0.42))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.white.opacity(0.11), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))

            HStack {
                Text("time")
                Spacer()
                Text("frequency ->")
                Spacer()
                Text("newer")
            }
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.42))
        }
    }

    private var visibleChannelIDs: [String] {
        let allScores = summaries.flatMap(\.channelScores)
        let twoGHzIDs = orderedChannelIDs(from: allScores.filter { $0.band == "2.4GHz" })
        if !twoGHzIDs.isEmpty {
            return twoGHzIDs
        }
        return orderedChannelIDs(from: allScores.filter { $0.band == "5GHz" })
    }

    private func orderedChannelIDs(from scores: [SidekickSpectrumChannelScore]) -> [String] {
        scores
            .reduce(into: [String: SidekickSpectrumChannelScore]()) { result, score in
                result[score.id] = score
            }
            .values
            .sorted {
                if $0.centerFrequencyMHz == $1.centerFrequencyMHz {
                    return $0.channel < $1.channel
                }
                return $0.centerFrequencyMHz < $1.centerFrequencyMHz
            }
            .map(\.id)
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
                .lineLimit(1)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minWidth: 72, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
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
