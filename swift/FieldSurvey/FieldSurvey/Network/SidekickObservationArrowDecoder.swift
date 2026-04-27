import Foundation
import Arrow

public enum SidekickObservationArrowDecoderError: Error, Equatable {
    case invalidStream(String)
    case missingColumn(String)
    case invalidColumnType(String)
}

public final class SidekickObservationArrowDecoder: @unchecked Sendable {
    public init() {}

    public func decode(_ payload: Data) throws -> [SidekickObservation] {
        let reader = ArrowReader()
        let result: ArrowReader.ArrowReaderResult

        switch reader.readStreaming(payload) {
        case .success(let readerResult):
            result = readerResult
        case .failure(let error):
            throw SidekickObservationArrowDecoderError.invalidStream(String(describing: error))
        }

        return try result.batches.flatMap(decodeBatch)
    }

    private func decodeBatch(_ batch: RecordBatch) throws -> [SidekickObservation] {
        let sidekickID = try stringColumn("sidekick_id", in: batch)
        let radioID = try stringColumn("radio_id", in: batch)
        let interfaceName = try stringColumn("interface_name", in: batch)
        let bssid = try stringColumn("bssid", in: batch)
        let ssid = try optionalStringColumn("ssid", in: batch)
        let hiddenSSID = try boolColumn("hidden_ssid", in: batch)
        let frameType = try stringColumn("frame_type", in: batch)
        let rssiDBM = try optionalInt16Column("rssi_dbm", in: batch)
        let noiseFloorDBM = try optionalInt16Column("noise_floor_dbm", in: batch)
        let snrDB = try optionalInt16Column("snr_db", in: batch)
        let frequencyMHz = try int32Column("frequency_mhz", in: batch)
        let channel = try optionalInt32Column("channel", in: batch)
        let channelWidthMHz = try optionalInt32Column("channel_width_mhz", in: batch)
        let capturedAtUnixNanos = try int64Column("captured_at_unix_nanos", in: batch)
        let capturedAtMonotonicNanos = try optionalInt64Column("captured_at_monotonic_nanos", in: batch)
        let parserConfidence = try doubleColumn("parser_confidence", in: batch)

        return (0..<batch.length).map { index in
            SidekickObservation(
                sidekickID: sidekickID[index] ?? "",
                radioID: radioID[index] ?? "",
                interfaceName: interfaceName[index] ?? "",
                bssid: bssid[index] ?? "",
                ssid: ssid[index],
                hiddenSSID: hiddenSSID[index] ?? false,
                frameType: frameType[index] ?? "unknown",
                rssiDBM: rssiDBM[index].map(Int.init),
                noiseFloorDBM: noiseFloorDBM[index].map(Int.init),
                snrDB: snrDB[index].map(Int.init),
                frequencyMHz: frequencyMHz[index].map(Int.init) ?? 0,
                channel: channel[index].map(Int.init),
                channelWidthMHz: channelWidthMHz[index].map(Int.init),
                capturedAtUnixNanos: capturedAtUnixNanos[index] ?? 0,
                capturedAtMonotonicNanos: capturedAtMonotonicNanos[index],
                parserConfidence: parserConfidence[index] ?? 0.0
            )
        }
        .filter { !$0.bssid.isEmpty }
    }

    private func stringColumn(_ name: String, in batch: RecordBatch) throws -> StringArray {
        guard let holder = batch.column(name) else {
            throw SidekickObservationArrowDecoderError.missingColumn(name)
        }
        guard let array = holder.array as? StringArray else {
            throw SidekickObservationArrowDecoderError.invalidColumnType(name)
        }
        return array
    }

    private func optionalStringColumn(_ name: String, in batch: RecordBatch) throws -> StringArray {
        try stringColumn(name, in: batch)
    }

    private func boolColumn(_ name: String, in batch: RecordBatch) throws -> BoolArray {
        guard let holder = batch.column(name) else {
            throw SidekickObservationArrowDecoderError.missingColumn(name)
        }
        guard let array = holder.array as? BoolArray else {
            throw SidekickObservationArrowDecoderError.invalidColumnType(name)
        }
        return array
    }

    private func optionalInt16Column(_ name: String, in batch: RecordBatch) throws -> FixedArray<Int16> {
        try fixedColumn(name, in: batch)
    }

    private func optionalInt32Column(_ name: String, in batch: RecordBatch) throws -> FixedArray<Int32> {
        try fixedColumn(name, in: batch)
    }

    private func int32Column(_ name: String, in batch: RecordBatch) throws -> FixedArray<Int32> {
        try fixedColumn(name, in: batch)
    }

    private func int64Column(_ name: String, in batch: RecordBatch) throws -> FixedArray<Int64> {
        try fixedColumn(name, in: batch)
    }

    private func optionalInt64Column(_ name: String, in batch: RecordBatch) throws -> FixedArray<Int64> {
        try fixedColumn(name, in: batch)
    }

    private func doubleColumn(_ name: String, in batch: RecordBatch) throws -> FixedArray<Double> {
        try fixedColumn(name, in: batch)
    }

    private func fixedColumn<T>(_ name: String, in batch: RecordBatch) throws -> FixedArray<T> {
        guard let holder = batch.column(name) else {
            throw SidekickObservationArrowDecoderError.missingColumn(name)
        }
        guard let array = holder.array as? FixedArray<T> else {
            throw SidekickObservationArrowDecoderError.invalidColumnType(name)
        }
        return array
    }
}
