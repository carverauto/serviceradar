// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import FlatBuffers
import Foundation

let FILEMARKER = "ARROW1"
let CONTINUATIONMARKER = UInt32(0xFFFFFFFF)

public class ArrowReader { // swiftlint:disable:this type_body_length
    private class RecordBatchData {
        let schema: org_apache_arrow_flatbuf_Schema
        let recordBatch: org_apache_arrow_flatbuf_RecordBatch
        private var fieldIndex: Int32 = 0
        private var nodeIndex: Int32 = 0
        private var bufferIndex: Int32 = 0
        init(_ recordBatch: org_apache_arrow_flatbuf_RecordBatch,
             schema: org_apache_arrow_flatbuf_Schema) {
            self.recordBatch = recordBatch
            self.schema = schema
        }

        func nextNode() -> org_apache_arrow_flatbuf_FieldNode? {
            if nodeIndex >= self.recordBatch.nodesCount {return nil}
            defer {nodeIndex += 1}
            return self.recordBatch.nodes(at: nodeIndex)
        }

        func nextBuffer() -> org_apache_arrow_flatbuf_Buffer? {
            if bufferIndex >= self.recordBatch.buffersCount {return nil}
            defer {bufferIndex += 1}
            return self.recordBatch.buffers(at: bufferIndex)
        }

        func nextField() -> org_apache_arrow_flatbuf_Field? {
            if fieldIndex >= self.schema.fieldsCount {return nil}
            defer {fieldIndex += 1}
            return self.schema.fields(at: fieldIndex)
        }

        func isDone() -> Bool {
            return nodeIndex >= self.recordBatch.nodesCount
        }
    }

    private struct DataLoadInfo {
        let fileData: Data
        let messageOffset: Int64
        var batchData: RecordBatchData
    }

    public class ArrowReaderResult {
        fileprivate var messageSchema: org_apache_arrow_flatbuf_Schema?
        public var schema: ArrowSchema?
        public var batches = [RecordBatch]()
    }

    public init() {}

    private func loadSchema(_ schema: org_apache_arrow_flatbuf_Schema) -> Result<ArrowSchema, ArrowError> {
        let builder = ArrowSchema.Builder()
        for index in 0 ..< schema.fieldsCount {
            let field = schema.fields(at: index)!
            let fieldType = findArrowType(field)
            if fieldType.info == ArrowType.ArrowUnknown {
                return .failure(.unknownType("Unsupported field type found: \(field.typeType)"))
            }
            let arrowField = ArrowField(field.name!, type: fieldType, isNullable: field.nullable)
            builder.addField(arrowField)
        }

        return .success(builder.finish())
    }

    private func loadStructData(_ loadInfo: DataLoadInfo,
                                field: org_apache_arrow_flatbuf_Field)
    -> Result<ArrowArrayHolder, ArrowError> {
        guard let node = loadInfo.batchData.nextNode() else {
            return .failure(.invalid("Node not found"))
        }

        guard let nullBuffer = loadInfo.batchData.nextBuffer() else {
            return .failure(.invalid("Null buffer not found"))
        }

        let nullLength = (UInt(node.length) + 7) / 8
        let arrowNullBuffer = makeBuffer(nullBuffer, fileData: loadInfo.fileData,
                                         length: nullLength, messageOffset: loadInfo.messageOffset)
        var children = [ArrowData]()
        for index in 0..<field.childrenCount {
            let childField = field.children(at: index)!
            switch loadField(loadInfo, field: childField) {
            case .success(let holder):
                children.append(holder.array.arrowData)
            case .failure(let error):
                return .failure(error)
            }
        }

        return makeArrayHolder(field, buffers: [arrowNullBuffer],
                               nullCount: UInt(node.nullCount), children: children,
                               rbLength: UInt(loadInfo.batchData.recordBatch.length))
    }

    private func loadListData(_ loadInfo: DataLoadInfo, field: org_apache_arrow_flatbuf_Field) -> Result<ArrowArrayHolder, ArrowError> {
        guard let node = loadInfo.batchData.nextNode() else {
            return .failure(.invalid("Node not found"))
        }

        guard let nullBuffer = loadInfo.batchData.nextBuffer() else {
            return .failure(.invalid("Null buffer not found"))
        }

        guard let offsetBuffer = loadInfo.batchData.nextBuffer() else {
            return .failure(.invalid("Offset buffer not found"))
        }

        let nullLength = (UInt(node.length) + 7) / 8
        let arrowNullBuffer = makeBuffer(nullBuffer, fileData: loadInfo.fileData, length: nullLength, messageOffset: loadInfo.messageOffset)
        let arrowOffsetBuffer = makeBuffer(offsetBuffer, fileData: loadInfo.fileData, length: UInt(node.length + 1), messageOffset: loadInfo.messageOffset)

        guard field.childrenCount == 1, let childField = field.children(at: 0) else {
            return .failure(.invalid("List must have exactly one child"))
        }

        switch loadField(loadInfo, field: childField) {
        case .success(let childHolder):
            return makeArrayHolder(field, buffers: [arrowNullBuffer, arrowOffsetBuffer], nullCount: UInt(node.nullCount), children: [childHolder.array.arrowData], rbLength: UInt(loadInfo.batchData.recordBatch.length))
        case .failure(let error):
            return .failure(error)
        }
    }

    private func loadPrimitiveData(
        _ loadInfo: DataLoadInfo,
        field: org_apache_arrow_flatbuf_Field)
    -> Result<ArrowArrayHolder, ArrowError> {
        guard let node = loadInfo.batchData.nextNode() else {
            return .failure(.invalid("Node not found"))
        }

        guard let nullBuffer = loadInfo.batchData.nextBuffer() else {
            return .failure(.invalid("Null buffer not found"))
        }

        guard let valueBuffer = loadInfo.batchData.nextBuffer() else {
            return .failure(.invalid("Value buffer not found"))
        }

        let nullLength = (UInt(node.length) + 7) / 8
        let arrowNullBuffer = makeBuffer(nullBuffer, fileData: loadInfo.fileData,
                                         length: nullLength, messageOffset: loadInfo.messageOffset)
        let arrowValueBuffer = makeBuffer(valueBuffer, fileData: loadInfo.fileData,
                                          length: UInt(node.length), messageOffset: loadInfo.messageOffset)
        return makeArrayHolder(field, buffers: [arrowNullBuffer, arrowValueBuffer],
                               nullCount: UInt(node.nullCount), children: nil,
                               rbLength: UInt(loadInfo.batchData.recordBatch.length))
    }

    private func loadVariableData(
        _ loadInfo: DataLoadInfo,
        field: org_apache_arrow_flatbuf_Field)
    -> Result<ArrowArrayHolder, ArrowError> {
        guard let node = loadInfo.batchData.nextNode() else {
            return .failure(.invalid("Node not found"))
        }

        guard let nullBuffer = loadInfo.batchData.nextBuffer() else {
            return .failure(.invalid("Null buffer not found"))
        }

        guard let offsetBuffer = loadInfo.batchData.nextBuffer() else {
            return .failure(.invalid("Offset buffer not found"))
        }

        guard let valueBuffer = loadInfo.batchData.nextBuffer() else {
            return .failure(.invalid("Value buffer not found"))
        }

        let nullLength = (UInt(node.length) + 7) / 8
        let arrowNullBuffer = makeBuffer(nullBuffer, fileData: loadInfo.fileData,
                                         length: nullLength, messageOffset: loadInfo.messageOffset)
        let arrowOffsetBuffer = makeBuffer(offsetBuffer, fileData: loadInfo.fileData,
                                           length: UInt(node.length), messageOffset: loadInfo.messageOffset)
        let arrowValueBuffer = makeBuffer(valueBuffer, fileData: loadInfo.fileData,
                                          length: UInt(node.length), messageOffset: loadInfo.messageOffset)
        return makeArrayHolder(field, buffers: [arrowNullBuffer, arrowOffsetBuffer, arrowValueBuffer],
                               nullCount: UInt(node.nullCount), children: nil,
                               rbLength: UInt(loadInfo.batchData.recordBatch.length))
    }

    private func loadField(
        _ loadInfo: DataLoadInfo,
        field: org_apache_arrow_flatbuf_Field)
    -> Result<ArrowArrayHolder, ArrowError> {
        switch field.typeType {
        case .struct_:
            return loadStructData(loadInfo, field: field)
        case .list:
            return loadListData(loadInfo, field: field)
        default:
            if isFixedPrimitive(field.typeType) {
                return loadPrimitiveData(loadInfo, field: field)
            } else {
                return loadVariableData(loadInfo, field: field)
            }
        }
    }

    private func loadRecordBatch(
        _ recordBatch: org_apache_arrow_flatbuf_RecordBatch,
        schema: org_apache_arrow_flatbuf_Schema,
        arrowSchema: ArrowSchema,
        data: Data,
        messageEndOffset: Int64
    ) -> Result<RecordBatch, ArrowError> {
        var columns: [ArrowArrayHolder] = []
        let batchData = RecordBatchData(recordBatch, schema: schema)
        let loadInfo = DataLoadInfo(fileData: data,
                                    messageOffset: messageEndOffset,
                                    batchData: batchData)
        while !batchData.isDone() {
            guard let field = batchData.nextField() else {
                return .failure(.invalid("Field not found"))
            }

            let result = loadField(loadInfo, field: field)
            switch result {
            case .success(let holder):
                columns.append(holder)
            case .failure(let error):
                return .failure(error)
            }
        }

        return .success(RecordBatch(arrowSchema, columns: columns))
    }

    /*
     This is for reading the Arrow streaming format. The Arrow streaming format
     is slightly different from the Arrow File format as it doesn't contain a header
     and footer.
     */
    public func readStreaming( // swiftlint:disable:this function_body_length
        _ input: Data,
        useUnalignedBuffers: Bool = false
    ) -> Result<ArrowReaderResult, ArrowError> {
        let result = ArrowReaderResult()
        var offset: Int = 0
        var length = getUInt32(input, offset: offset)
        var streamData = input
        var schemaMessage: org_apache_arrow_flatbuf_Schema?
        while length != 0 {
            if length == CONTINUATIONMARKER {
                offset += Int(MemoryLayout<UInt32>.size)
                length = getUInt32(input, offset: offset)
                if length == 0 {
                    return .success(result)
                }
            }

            offset += Int(MemoryLayout<UInt32>.size)
            streamData = input[(input.startIndex + offset)...]
            var dataBuffer = ByteBuffer(
                data: streamData,
                allowReadingUnalignedBuffers: useUnalignedBuffers
            )
            let message: org_apache_arrow_flatbuf_Message = getRoot(byteBuffer: &dataBuffer)
            switch message.headerType {
            case .recordbatch:
                guard let rbMessage = message.header(type: org_apache_arrow_flatbuf_RecordBatch.self) else {
                    return .failure(.invalid("RecordBatch header not found"))
                }
                guard let schemaMsg = schemaMessage else {
                    return .failure(.invalid("Schema must be defined before RecordBatch"))
                }
                guard let schema = result.schema else {
                    return .failure(.invalid("Schema not loaded"))
                }
                let recordBatchResult = loadRecordBatch(
                    rbMessage,
                    schema: schemaMsg,
                    arrowSchema: schema,
                    data: input,
                    messageEndOffset: (Int64(offset) + Int64(length)))
                switch recordBatchResult {
                case .success(let recordBatch):
                    result.batches.append(recordBatch)
                case .failure(let error):
                    return .failure(error)
                }
                offset += Int(message.bodyLength + Int64(length))
                length = getUInt32(input, offset: offset)
            case .schema:
                schemaMessage = message.header(type: org_apache_arrow_flatbuf_Schema.self)!
                let schemaResult = loadSchema(schemaMessage!)
                switch schemaResult {
                case .success(let schema):
                    result.schema = schema
                case .failure(let error):
                    return .failure(error)
                }
                offset += Int(message.bodyLength + Int64(length))
                length = getUInt32(input, offset: offset)
            default:
                return .failure(.unknownError("Unhandled header type: \(message.headerType)"))
            }
        }
        return .success(result)
    }

    /*
     This is for reading the Arrow file format. The Arrow file format supports
     random accessing the data.  The Arrow file format contains a header and
     footer around the Arrow streaming format.
     */
    public func readFile( // swiftlint:disable:this function_body_length
        _ fileData: Data,
        useUnalignedBuffers: Bool = false
    ) -> Result<ArrowReaderResult, ArrowError> {
        let footerLength = fileData.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: fileData.count - 4, as: Int32.self)
        }

        let result = ArrowReaderResult()
        let footerStartOffset = fileData.count - Int(footerLength + 4)
        let footerData = fileData[footerStartOffset...]
        var footerBuffer = ByteBuffer(
            data: footerData,
            allowReadingUnalignedBuffers: useUnalignedBuffers)
        let footer: org_apache_arrow_flatbuf_Footer = getRoot(byteBuffer: &footerBuffer)
        guard let footerSchema = footer.schema else {
            return .failure(.invalid("Footer schema not found"))
        }
        let schemaResult = loadSchema(footerSchema)
        switch schemaResult {
        case .success(let schema):
            result.schema = schema
        case .failure(let error):
            return .failure(error)
        }

        for index in 0 ..< footer.recordBatchesCount {
            let recordBatch = footer.recordBatches(at: index)!
            var messageLength = fileData.withUnsafeBytes { rawBuffer in
                rawBuffer.loadUnaligned(fromByteOffset: Int(recordBatch.offset), as: UInt32.self)
            }

            var messageOffset: Int64 = 1
            if messageLength == CONTINUATIONMARKER {
                messageOffset += 1
                messageLength = fileData.withUnsafeBytes { rawBuffer in
                    rawBuffer.loadUnaligned(
                        fromByteOffset: Int(recordBatch.offset + Int64(MemoryLayout<Int32>.size)),
                        as: UInt32.self)
                }
            }

            let messageStartOffset = recordBatch.offset + (Int64(MemoryLayout<Int32>.size) * messageOffset)
            let messageEndOffset = messageStartOffset + Int64(messageLength)
            let recordBatchData = fileData[messageStartOffset ..< messageEndOffset]
            var mbb = ByteBuffer(
                data: recordBatchData,
                allowReadingUnalignedBuffers: useUnalignedBuffers)
            let message: org_apache_arrow_flatbuf_Message = getRoot(byteBuffer: &mbb)
            switch message.headerType {
            case .recordbatch:
                guard let rbMessage = message.header(type: org_apache_arrow_flatbuf_RecordBatch.self) else {
                    return .failure(.invalid("RecordBatch header not found"))
                }
                guard let schema = result.schema else {
                    return .failure(.invalid("Schema not loaded"))
                }
                let recordBatchResult = loadRecordBatch(
                    rbMessage,
                    schema: footerSchema,
                    arrowSchema: schema,
                    data: fileData,
                    messageEndOffset: messageEndOffset)
                switch recordBatchResult {
                case .success(let recordBatch):
                    result.batches.append(recordBatch)
                case .failure(let error):
                    return .failure(error)
                }
            default:
                return .failure(.unknownError("Unhandled header type: \(message.headerType)"))
            }
        }

        return .success(result)
    }

    public func fromFile(_ fileURL: URL) -> Result<ArrowReaderResult, ArrowError> {
        do {
            let fileData = try Data(contentsOf: fileURL)
            if !validateFileData(fileData) {
                return .failure(.ioError("Not a valid arrow file."))
            }

            let markerLength = FILEMARKER.utf8.count
            let footerLengthEnd = Int(fileData.count - markerLength)
            let data = fileData[..<(footerLengthEnd)]
            return readFile(data)
        } catch {
            return .failure(.unknownError("Error loading file: \(error)"))
        }
    }

    static public func makeArrowReaderResult() -> ArrowReaderResult {
        return ArrowReaderResult()
    }

    public func fromMessage(
        _ dataHeader: Data,
        dataBody: Data,
        result: ArrowReaderResult,
        useUnalignedBuffers: Bool = false
    ) -> Result<Void, ArrowError> {
        var mbb = ByteBuffer(
            data: dataHeader,
            allowReadingUnalignedBuffers: useUnalignedBuffers)
        let message: org_apache_arrow_flatbuf_Message = getRoot(byteBuffer: &mbb)
        switch message.headerType {
        case .schema:
            guard let sMessage = message.header(type: org_apache_arrow_flatbuf_Schema.self) else {
                return .failure(.invalid("Schema header not found"))
            }
            switch loadSchema(sMessage) {
            case .success(let schema):
                result.schema = schema
                result.messageSchema = sMessage
                return .success(())
            case .failure(let error):
                return .failure(error)
            }
        case .recordbatch:
            guard let rbMessage = message.header(type: org_apache_arrow_flatbuf_RecordBatch.self) else {
                return .failure(.invalid("RecordBatch header not found"))
            }
            guard let messageSchema = result.messageSchema else {
                return .failure(.invalid("Schema must be defined before RecordBatch"))
            }
            guard let schema = result.schema else {
                return .failure(.invalid("Schema not loaded"))
            }
            let recordBatchResult = loadRecordBatch(
                rbMessage, schema: messageSchema, arrowSchema: schema,
                data: dataBody, messageEndOffset: 0)
            switch recordBatchResult {
            case .success(let recordBatch):
                result.batches.append(recordBatch)
                return .success(())
            case .failure(let error):
                return .failure(error)
            }
        default:
            return .failure(.unknownError("Unhandled header type: \(message.headerType)"))
        }
    }

}
// swiftlint:disable:this file_length
