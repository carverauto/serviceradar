#if os(iOS)
import SwiftUI
import UIKit

@available(iOS 16.0, *)
public struct HomeDashboardView: View {
    @ObservedObject var roomScanner: RoomScanner
    @ObservedObject var wifiScanner: RealWiFiScanner
    @ObservedObject var sessionStore: SurveySessionStore
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var subnetScanner = SubnetScanner.shared

    @State private var showSurvey = false
    @State private var showSettings = false
    @State private var showSessions = false
    @State private var showSubnetIntel = false
    @State private var showAPIntel = false
    @State private var showSignalMap = false
    @State private var resumeSnapshot: SurveySessionSnapshot?

    public init(roomScanner: RoomScanner, wifiScanner: RealWiFiScanner, sessionStore: SurveySessionStore) {
        self.roomScanner = roomScanner
        self.wifiScanner = wifiScanner
        self.sessionStore = sessionStore
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.03, blue: 0.08), Color(red: 0.07, green: 0.0, blue: 0.12), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            CyberGridBackdrop()
                .ignoresSafeArea()
                .opacity(0.55)

            VStack(spacing: 26) {
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.2, green: 0.98, blue: 0.9).opacity(0.14))
                            .frame(width: 88, height: 88)
                        Circle()
                            .stroke(Color(red: 0.98, green: 0.34, blue: 0.78).opacity(0.6), lineWidth: 1.2)
                            .frame(width: 94, height: 94)

                        Image("serviceradar_logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 54, height: 54)
                    }

                    Text("FIELDSURVEY")
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .foregroundColor(Color(red: 0.2, green: 0.98, blue: 0.9))
                        .shadow(color: Color(red: 0.2, green: 0.98, blue: 0.9).opacity(0.7), radius: 12)

                    Text("ServiceRadar // RF + LiDAR Recon")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.78))
                }
                .padding(.top, 42)

                VStack(spacing: 12) {
                    HomeActionButton(
                        title: "Start",
                        subtitle: "Enter LiDAR/AR capture",
                        icon: "play.fill",
                        accent: Color(red: 0.2, green: 0.98, blue: 0.9)
                    ) {
                        showSurvey = true
                    }

                    HomeActionButton(
                        title: "Sessions",
                        subtitle: "\(sessionStore.sessions.count) saved scans",
                        icon: "folder.fill",
                        accent: Color(red: 0.98, green: 0.34, blue: 0.78)
                    ) {
                        showSessions = true
                    }

                    HomeActionButton(
                        title: "Signal Map",
                        subtitle: "\(wifiScanner.heatmapPoints.count) live heat points",
                        icon: "chart.dots.scatter",
                        accent: Color(red: 0.35, green: 0.86, blue: 0.38)
                    ) {
                        showSignalMap = true
                    }

                    HomeActionButton(
                        title: "Settings",
                        subtitle: settings.rfScanningEnabled ? "RF online" : "RF paused",
                        icon: "gearshape.fill",
                        accent: Color(red: 1.0, green: 0.55, blue: 0.18)
                    ) {
                        showSettings = true
                    }

                    HomeActionButton(
                        title: "ServiceRadar",
                        subtitle: settings.apiURL,
                        icon: "safari.fill",
                        accent: Color(red: 0.44, green: 0.62, blue: 1.0)
                    ) {
                        openServiceRadar()
                    }
                }
                .padding(.horizontal, 22)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Live Intel")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))

                    Text("APs: \(wifiScanner.accessPoints.count)   Mapped: \(wifiScanner.resolvedAPLocations.count)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(red: 0.4, green: 0.95, blue: 1.0))

                    Text("Subnet Hosts: \(subnetScanner.discoveredDevices.count)   Roams: \(wifiScanner.roamEvents.count)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.84))

                    Button(action: {
                        showAPIntel = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "list.bullet.rectangle.portrait")
                            Text("Open AP Intel")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(red: 0.44, green: 0.62, blue: 1.0))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }

                    Button(action: {
                        showSubnetIntel = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "network")
                            Text("Open Subnet Intel")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(red: 0.2, green: 0.98, blue: 0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.black.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 22)

                Spacer()
            }
        }
        .fullScreenCover(isPresented: $showSurvey) {
            SurveyView(
                roomScanner: roomScanner,
                wifiScanner: wifiScanner,
                sessionStore: sessionStore,
                resumeSnapshot: resumeSnapshot
            ) {
                showSurvey = false
                resumeSnapshot = nil
            }
        }
        .sheet(isPresented: $showSessions) {
            SessionLibraryView(
                roomScanner: roomScanner,
                wifiScanner: wifiScanner,
                sessionStore: sessionStore,
                onResume: { snapshot in
                    resumeSnapshot = snapshot
                    showSurvey = true
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAPIntel) {
            APIntelView(wifiScanner: wifiScanner)
        }
        .sheet(isPresented: $showSignalMap) {
            SignalMapView(
                title: "Live Signal Map",
                points: wifiScanner.heatmapPoints,
                landmarks: wifiScanner.manualAPLandmarks,
                currentPose: wifiScanner.currentDevicePose
            )
        }
        .sheet(isPresented: $showSubnetIntel) {
            SubnetIntelView()
        }
    }

    private func openServiceRadar() {
        let raw = settings.apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let urlString = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://\(raw)"
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

@available(iOS 16.0, *)
public struct SessionLibraryView: View {
    @Environment(\.dismiss) var dismiss

    @ObservedObject var roomScanner: RoomScanner
    @ObservedObject var wifiScanner: RealWiFiScanner
    @ObservedObject var sessionStore: SurveySessionStore

    let onResume: ((SurveySessionSnapshot) -> Void)?

    @State private var compareMessage: String?
    @State private var loadMessage: String?
    @State private var reviewSnapshot: SurveySessionSnapshot?

    public init(
        roomScanner: RoomScanner,
        wifiScanner: RealWiFiScanner,
        sessionStore: SurveySessionStore,
        onResume: ((SurveySessionSnapshot) -> Void)? = nil
    ) {
        self.roomScanner = roomScanner
        self.wifiScanner = wifiScanner
        self.sessionStore = sessionStore
        self.onResume = onResume
    }

    public var body: some View {
        NavigationView {
            List {
                if sessionStore.sessions.isEmpty {
                    Text("No sessions saved yet.")
                        .foregroundColor(.gray)
                } else {
                    ForEach(sessionStore.sessions) { session in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(session.name)
                                .font(.headline)

                            Text(sessionDate(session.createdAt))
                                .font(.caption)
                                .foregroundColor(.gray)

                            Text(sessionSummary(session))
                                .font(.caption2)
                                .foregroundColor(.cyan)

                            HStack(spacing: 12) {
                                Button("Resume") {
                                    load(session)
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Review") {
                                    review(session)
                                }
                                .buttonStyle(.bordered)

                                Button("Compare") {
                                    compareWithCurrent(session)
                                }
                                .buttonStyle(.bordered)

                                Button("Delete", role: .destructive) {
                                    sessionStore.deleteSession(id: session.id)
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Survey Sessions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Session Compare", isPresented: Binding(
                get: { compareMessage != nil },
                set: { if !$0 { compareMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(compareMessage ?? "")
            }
            .alert("Session Load", isPresented: Binding(
                get: { loadMessage != nil },
                set: { if !$0 { loadMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(loadMessage ?? "")
            }
            .sheet(item: $reviewSnapshot) { snapshot in
                SignalMapView(
                    title: snapshot.record.name,
                    points: snapshot.heatmapPoints,
                    landmarks: snapshot.manualLandmarks,
                    spectrumSummary: snapshot.spectrumSummaries.last,
                    spectrumSummaries: snapshot.spectrumSummaries
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    private func load(_ session: SurveySessionRecord) {
        guard let snapshot = sessionStore.loadSession(id: session.id) else {
            loadMessage = "Failed to load session snapshot."
            return
        }
        wifiScanner.loadSessionSnapshot(snapshot)
        onResume?(snapshot)
        dismiss()
    }

    private func review(_ session: SurveySessionRecord) {
        guard let snapshot = sessionStore.loadSession(id: session.id) else {
            loadMessage = "Failed to load session snapshot."
            return
        }
        reviewSnapshot = snapshot
    }

    private func compareWithCurrent(_ session: SurveySessionRecord) {
        guard let result = sessionStore.compareAgainstCurrent(
            session: session,
            currentSamples: Array(wifiScanner.accessPoints.values)
        ) else {
            compareMessage = "Unable to compare this session."
            return
        }

        compareMessage = "Overlap: \(result.overlapCount) APs\nAvg RSSI delta: \(String(format: "%.1f", result.averageRSSIDelta)) dBm\nImproved: \(result.improvedCount) • Degraded: \(result.degradedCount)"
    }

    private func sessionDate(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private func sessionSummary(_ session: SurveySessionRecord) -> String {
        let spectrumCount = sessionStore.loadSession(id: session.id)?.spectrumSummaries.count ?? 0
        return "Samples \(session.sampleCount) • Heat \(session.heatmapPointCount) • AP labels \(session.manualLandmarkCount) • Spectrum \(spectrumCount)"
    }
}

@available(iOS 16.0, *)
public struct SubnetIntelView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var subnetScanner = SubnetScanner.shared
    @State private var filter: String = ""

    public init() {}

    public var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                HStack {
                    Text("Hosts: \(filteredDevices.count)")
                        .font(.caption)
                        .foregroundColor(.cyan)
                    Spacer()
                    Button("Refresh Sweep") {
                        SubnetScanner.shared.stopScanning()
                        SubnetScanner.shared.startScanning()
                    }
                    .font(.caption)
                }

                TextField("Filter host or IP", text: $filter)
                    .textFieldStyle(.roundedBorder)

                List(filteredDevices, id: \.0) { key, value in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(value.hostname)
                            .font(.subheadline)
                        Text(value.ip)
                            .font(.caption)
                            .foregroundColor(.cyan)
                    }
                }
            }
            .padding()
            .navigationTitle("Subnet Sweep Intel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var filteredDevices: [(String, (ip: String, hostname: String))] {
        let sorted = subnetScanner.discoveredDevices.sorted { $0.value.hostname < $1.value.hostname }
        let cleanFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanFilter.isEmpty else { return sorted }

        return sorted.filter { _, value in
            value.hostname.lowercased().contains(cleanFilter) || value.ip.lowercased().contains(cleanFilter)
        }
    }
}

@available(iOS 16.0, *)
public struct APIntelView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var wifiScanner: RealWiFiScanner

    @State private var filter: String = ""
    @State private var scope: APScope = .wifi
    @State private var sortOrder: APSortOrder = .strongest
    @State private var editingManualAPId: String?
    @State private var editingManualAPLabel: String = ""

    public init(wifiScanner: RealWiFiScanner) {
        self.wifiScanner = wifiScanner
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Visible records: \(filteredSamples.count) / \(wifiScanner.accessPoints.count)")
                        .font(.caption)
                        .foregroundColor(.cyan)

                    Text("Channels seen: \(channelsSeenText)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(2)

                    Text("Manual APs: \(wifiScanner.manualAPLandmarks.count) (swipe manual rows to edit/delete)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextField("Filter SSID / BSSID / host / IP", text: $filter)
                    .textFieldStyle(.roundedBorder)

                Picker("Type", selection: $scope) {
                    ForEach(APScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Sort", selection: $sortOrder) {
                    ForEach(APSortOrder.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                List(filteredSamples, id: \.bssid) { sample in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(displayName(for: sample))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .lineLimit(1)

                            Spacer()
                            Text("\(Int(sample.rssi)) dBm")
                                .font(.caption)
                                .foregroundColor(colorForRSSI(sample.rssi))
                        }

                        Text(sample.bssid)
                            .font(.caption2)
                            .foregroundColor(.gray)

                        HStack(spacing: 10) {
                            Text(typeLabel(for: sample))
                            Text("\(bandLabel(for: sample.frequency)) • Ch \(channelLabel(for: sample.frequency))")
                            if !sample.ipAddress.isEmpty {
                                Text(sample.ipAddress)
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.cyan)
                        .lineLimit(1)

                        HStack(spacing: 10) {
                            Text(sample.isSecure ? "Secure" : "Open")
                            if !sample.hostname.isEmpty {
                                Text(sample.hostname)
                            }
                            Text("Age \(sampleAgeSeconds(sample))s")
                        }
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if let manualId = manualLandmarkID(for: sample) {
                            Button {
                                beginManualEdit(id: manualId)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)

                            Button(role: .destructive) {
                                wifiScanner.deleteManualAccessPoint(id: manualId)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("AP Intel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: isEditingManualAPBinding) {
            NavigationView {
                Form {
                    Section(header: Text("Manual AP")) {
                        TextField("Label", text: $editingManualAPLabel)
                    }
                }
                .navigationTitle("Edit AP Label")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            clearManualEdit()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            guard let id = editingManualAPId else { return }
                            wifiScanner.renameManualAccessPoint(id: id, newLabel: editingManualAPLabel)
                            clearManualEdit()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var filteredSamples: [SurveySample] {
        let cleanFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = Array(wifiScanner.accessPoints.values)
            .filter { sample in
                switch scope {
                case .all:
                    return true
                case .wifi:
                    return sampleCategory(sample) == .wifi
                case .mdns:
                    return sampleCategory(sample) == .mdns
                case .manual:
                    return sampleCategory(sample) == .manual
                }
            }
            .filter { sample in
                guard !cleanFilter.isEmpty else { return true }
                return sample.ssid.lowercased().contains(cleanFilter)
                    || sample.bssid.lowercased().contains(cleanFilter)
                    || sample.hostname.lowercased().contains(cleanFilter)
                    || sample.ipAddress.lowercased().contains(cleanFilter)
            }

        switch sortOrder {
        case .strongest:
            return base.sorted { lhs, rhs in
                if lhs.rssi == rhs.rssi { return lhs.timestamp > rhs.timestamp }
                return lhs.rssi > rhs.rssi
            }
        case .newest:
            return base.sorted { $0.timestamp > $1.timestamp }
        case .ssid:
            return base.sorted { displayName(for: $0) < displayName(for: $1) }
        }
    }

    private var channelsSeenText: String {
        let channels = Set(
            wifiScanner.accessPoints.values
                .filter { sampleCategory($0) == .wifi }
                .map { channelLabel(for: $0.frequency) }
                .filter { $0 != "-" }
        ).sorted { lhs, rhs in
            (Int(lhs) ?? 0) < (Int(rhs) ?? 0)
        }
        if channels.isEmpty { return "n/a" }
        return channels.prefix(24).joined(separator: ", ")
    }

    private func displayName(for sample: SurveySample) -> String {
        let trimmed = sample.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "<hidden>" : trimmed
    }

    private func sampleAgeSeconds(_ sample: SurveySample) -> Int {
        max(Int(Date().timeIntervalSince1970 - sample.timestamp), 0)
    }

    private func colorForRSSI(_ rssi: Double) -> Color {
        if rssi >= -55 { return .green }
        if rssi >= -68 { return .yellow }
        if rssi >= -78 { return .orange }
        return .red
    }

    private func typeLabel(for sample: SurveySample) -> String {
        switch sampleCategory(sample) {
        case .wifi: return "Wi-Fi"
        case .mdns: return "mDNS"
        case .manual: return "Manual"
        }
    }

    private func sampleCategory(_ sample: SurveySample) -> APDerivedCategory {
        if sample.bssid.hasPrefix("manual-ap-") {
            return .manual
        }
        if sample.bssid.hasPrefix("mdns-") || sample.securityType.localizedCaseInsensitiveContains("mdns") || sample.frequency == 0 {
            return .mdns
        }
        return .wifi
    }

    private func bandLabel(for frequency: Int) -> String {
        if frequency >= 5925 { return "6 GHz" }
        if frequency >= 5000 { return "5 GHz" }
        if frequency >= 2400 { return "2.4 GHz" }
        return "Unknown"
    }

    private func channelLabel(for frequency: Int) -> String {
        if frequency == 2484 { return "14" }
        if frequency >= 2412 && frequency <= 2472 {
            return String((frequency - 2407) / 5)
        }
        if frequency >= 5000 && frequency <= 5895 {
            return String((frequency - 5000) / 5)
        }
        if frequency >= 5955 && frequency <= 7115 {
            return String((frequency - 5950) / 5)
        }
        return "-"
    }

    private var isEditingManualAPBinding: Binding<Bool> {
        Binding(
            get: { editingManualAPId != nil },
            set: { shouldShow in
                if !shouldShow {
                    clearManualEdit()
                }
            }
        )
    }

    private func manualLandmarkID(for sample: SurveySample) -> String? {
        guard sampleCategory(sample) == .manual else { return nil }
        let prefix = "manual-ap-"
        guard sample.bssid.hasPrefix(prefix) else { return nil }
        return String(sample.bssid.dropFirst(prefix.count))
    }

    private func beginManualEdit(id: String) {
        guard let landmark = wifiScanner.manualAPLandmarks.first(where: { $0.id == id }) else { return }
        editingManualAPId = id
        editingManualAPLabel = landmark.label
    }

    private func clearManualEdit() {
        editingManualAPId = nil
        editingManualAPLabel = ""
    }

    private enum APScope: String, CaseIterable, Identifiable {
        case all
        case wifi
        case mdns
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .wifi: return "Wi-Fi"
            case .mdns: return "mDNS"
            case .manual: return "Manual"
            }
        }
    }

    private enum APSortOrder: String, CaseIterable, Identifiable {
        case strongest
        case newest
        case ssid

        var id: String { rawValue }

        var title: String {
            switch self {
            case .strongest: return "RSSI"
            case .newest: return "Newest"
            case .ssid: return "SSID"
            }
        }
    }

    private enum APDerivedCategory {
        case wifi
        case mdns
        case manual
    }
}

@available(iOS 16.0, *)
public struct AppSplashView: View {
    @State private var pulse = false

    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.07, green: 0.0, blue: 0.12), Color(red: 0.0, green: 0.1, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            CyberGridBackdrop()
                .ignoresSafeArea()
                .opacity(0.6)

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.2, green: 0.98, blue: 0.9).opacity(0.14))
                        .frame(width: 104, height: 104)
                    Circle()
                        .stroke(Color(red: 1.0, green: 0.44, blue: 0.82).opacity(0.65), lineWidth: 1.4)
                        .frame(width: 112, height: 112)

                    Image("serviceradar_logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 70, height: 70)
                        .shadow(color: Color(red: 0.2, green: 0.98, blue: 0.9).opacity(0.65), radius: 10)
                }

                Text("SERVICERADAR")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 1.0, green: 0.44, blue: 0.82))

                Text("FIELD SURVEY")
                    .font(.system(size: 46, weight: .black, design: .rounded))
                    .foregroundColor(Color(red: 0.2, green: 0.98, blue: 0.9))
                    .shadow(color: Color(red: 0.2, green: 0.98, blue: 0.9).opacity(pulse ? 0.9 : 0.35), radius: pulse ? 22 : 8)

                Text("NOCTURNE MODE // LINKING SENSORS")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

@available(iOS 16.0, *)
private struct CyberGridBackdrop: View {
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let spacing: CGFloat = 28
                var grid = Path()

                let horizontalOffset = CGFloat((t * 22).truncatingRemainder(dividingBy: Double(spacing)))
                var y: CGFloat = -spacing + horizontalOffset
                while y < size.height + spacing {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }

                var x: CGFloat = 0
                while x < size.width + spacing {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }

                context.stroke(
                    grid,
                    with: .color(Color(red: 0.2, green: 0.98, blue: 0.9).opacity(0.12)),
                    lineWidth: 0.6
                )

                let center = CGPoint(x: size.width * 0.8, y: size.height * 0.2)
                let pulse = 110 + sin(t * 1.4 + phase) * 28
                let glowRect = CGRect(x: center.x - pulse, y: center.y - pulse, width: pulse * 2, height: pulse * 2)
                context.fill(
                    Path(ellipseIn: glowRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(red: 1.0, green: 0.3, blue: 0.7).opacity(0.25),
                            .clear
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: pulse
                    )
                )
            }
        }
        .onAppear {
            phase = .random(in: 0...(Double.pi * 2.0))
        }
    }
}

@available(iOS 16.0, *)
private struct HomeActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(14)
            .background(Color.black.opacity(0.45))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(accent.opacity(0.5), lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}
#endif
