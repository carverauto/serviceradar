import Foundation
import XCTest
@testable import Arrow
final class ArrowCompatibilityTests: XCTestCase {
    func testFieldSurveyAPIsRoundTrip() throws {
        let text = try ArrowArrayBuilders.loadStringArrayBuilder()
        text.append(["host01.example.com", nil])
        let flag = try ArrowArrayBuilders.loadBoolArrayBuilder()
        flag.append([true, nil])
        let i16 = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int16>
        i16.append([-17, nil])
        let i32 = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int32>
        i32.append([42, nil])
        let i64 = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int64>
        i64.append([9_007_199_254_740_993, nil])
        let f32 = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Float>
        f32.append([1.25, nil])
        let f64 = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Double>
        f64.append([2.5, nil])
        let timestamp = try ArrowArrayBuilders.loadTimestampArrayBuilder(.microseconds)
        timestamp.append([1_000_000, nil])
        let batch = try RecordBatch.Builder()
            .addColumn("text", arrowArray: text.toHolder())
            .addColumn("flag", arrowArray: flag.toHolder())
            .addColumn("i16", arrowArray: i16.toHolder())
            .addColumn("i32", arrowArray: i32.toHolder())
            .addColumn("i64", arrowArray: i64.toHolder())
            .addColumn("f32", arrowArray: f32.toHolder())
            .addColumn("f64", arrowArray: f64.toHolder())
            .addColumn("timestamp", arrowArray: timestamp.toHolder())
            .finish().get()
        let bytes = try ArrowWriter().writeStreaming(ArrowWriter.Info(.recordbatch, schema: batch.schema, batches: [batch])).get()
        let decoded = try ArrowReader().readStreaming(bytes, useUnalignedBuffers: true).get().batches[0]
        XCTAssertEqual(decoded.length, 2)
        XCTAssertEqual((decoded.column("text")!.array as! StringArray)[0], "host01.example.com")
        XCTAssertNil((decoded.column("text")!.array as! StringArray)[1])
        XCTAssertEqual((decoded.column("flag")!.array as! BoolArray)[0], true)
        XCTAssertNil((decoded.column("flag")!.array as! BoolArray)[1])
        XCTAssertEqual((decoded.column("i16")!.array as! FixedArray<Int16>)[0], -17)
        XCTAssertNil((decoded.column("i16")!.array as! FixedArray<Int16>)[1])
        XCTAssertEqual((decoded.column("i32")!.array as! FixedArray<Int32>)[0], 42)
        XCTAssertNil((decoded.column("i32")!.array as! FixedArray<Int32>)[1])
        XCTAssertEqual((decoded.column("i64")!.array as! FixedArray<Int64>)[0], 9_007_199_254_740_993)
        XCTAssertNil((decoded.column("i64")!.array as! FixedArray<Int64>)[1])
        XCTAssertEqual((decoded.column("f32")!.array as! FixedArray<Float>)[0], 1.25)
        XCTAssertNil((decoded.column("f32")!.array as! FixedArray<Float>)[1])
        XCTAssertEqual((decoded.column("f64")!.array as! FixedArray<Double>)[0], 2.5)
        XCTAssertNil((decoded.column("f64")!.array as! FixedArray<Double>)[1])
        XCTAssertEqual((decoded.column("timestamp")!.array as! TimestampArray)[0], 1_000_000)
        XCTAssertNil((decoded.column("timestamp")!.array as! TimestampArray)[1])
    }
    func testOmittedValidityBuffer() throws {
        let builder = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int64>
        builder.append(47)
        let values = try builder.finish()
        let data = try ArrowData(values.arrowData.type, buffers: [ArrowBuffer.createEmptyBuffer(), values.arrowData.buffers[1]], nullCount: 0)
        let array = try FixedArray<Int64>(data)
        let batch = try RecordBatch.Builder().addColumn("value", arrowArray: ArrowArrayHolderImpl(array)).finish().get()
        let bytes = try ArrowWriter().writeStreaming(ArrowWriter.Info(.recordbatch, schema: batch.schema, batches: [batch])).get()
        for _ in 0..<20 {
            let decoded = try ArrowReader().readStreaming(bytes, useUnalignedBuffers: true).get().batches[0]
            XCTAssertEqual((decoded.column("value")!.array as! FixedArray<Int64>)[0], 47)
        }
    }
}
