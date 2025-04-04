//
// Copyright 2025 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Code generated by protoc-gen-go. DO NOT EDIT.
// versions:
// 	protoc-gen-go v1.36.5
// 	protoc        v5.29.3
// source: rperf/rperf.proto

package rperf

import (
	protoreflect "google.golang.org/protobuf/reflect/protoreflect"
	protoimpl "google.golang.org/protobuf/runtime/protoimpl"
	reflect "reflect"
	sync "sync"
	unsafe "unsafe"
)

const (
	// Verify that this generated code is sufficiently up-to-date.
	_ = protoimpl.EnforceVersion(20 - protoimpl.MinVersion)
	// Verify that runtime/protoimpl is sufficiently up-to-date.
	_ = protoimpl.EnforceVersion(protoimpl.MaxVersion - 20)
)

// Test request parameters
type TestRequest struct {
	state         protoimpl.MessageState `protogen:"open.v1"`
	TargetAddress string                 `protobuf:"bytes,1,opt,name=target_address,json=targetAddress,proto3" json:"target_address,omitempty"`   // The server to connect to
	Port          uint32                 `protobuf:"varint,2,opt,name=port,proto3" json:"port,omitempty"`                                         // The port to connect to
	Protocol      string                 `protobuf:"bytes,3,opt,name=protocol,proto3" json:"protocol,omitempty"`                                  // "tcp" or "udp"
	Reverse       bool                   `protobuf:"varint,4,opt,name=reverse,proto3" json:"reverse,omitempty"`                                   // Whether to run in reverse mode
	Bandwidth     uint64                 `protobuf:"varint,5,opt,name=bandwidth,proto3" json:"bandwidth,omitempty"`                               // Target bandwidth in bytes/sec
	Duration      float64                `protobuf:"fixed64,6,opt,name=duration,proto3" json:"duration,omitempty"`                                // Test duration in seconds
	Parallel      uint32                 `protobuf:"varint,7,opt,name=parallel,proto3" json:"parallel,omitempty"`                                 // Number of parallel streams
	Length        uint32                 `protobuf:"varint,8,opt,name=length,proto3" json:"length,omitempty"`                                     // Length of buffer to use
	Omit          uint32                 `protobuf:"varint,9,opt,name=omit,proto3" json:"omit,omitempty"`                                         // Seconds to omit from the start
	NoDelay       bool                   `protobuf:"varint,10,opt,name=no_delay,json=noDelay,proto3" json:"no_delay,omitempty"`                   // Use TCP no-delay option
	SendBuffer    uint32                 `protobuf:"varint,11,opt,name=send_buffer,json=sendBuffer,proto3" json:"send_buffer,omitempty"`          // Socket send buffer size
	ReceiveBuffer uint32                 `protobuf:"varint,12,opt,name=receive_buffer,json=receiveBuffer,proto3" json:"receive_buffer,omitempty"` // Socket receive buffer size
	SendInterval  float64                `protobuf:"fixed64,13,opt,name=send_interval,json=sendInterval,proto3" json:"send_interval,omitempty"`   // Send interval in seconds
	unknownFields protoimpl.UnknownFields
	sizeCache     protoimpl.SizeCache
}

func (x *TestRequest) Reset() {
	*x = TestRequest{}
	mi := &file_rperf_rperf_proto_msgTypes[0]
	ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
	ms.StoreMessageInfo(mi)
}

func (x *TestRequest) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*TestRequest) ProtoMessage() {}

func (x *TestRequest) ProtoReflect() protoreflect.Message {
	mi := &file_rperf_rperf_proto_msgTypes[0]
	if x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use TestRequest.ProtoReflect.Descriptor instead.
func (*TestRequest) Descriptor() ([]byte, []int) {
	return file_rperf_rperf_proto_rawDescGZIP(), []int{0}
}

func (x *TestRequest) GetTargetAddress() string {
	if x != nil {
		return x.TargetAddress
	}
	return ""
}

func (x *TestRequest) GetPort() uint32 {
	if x != nil {
		return x.Port
	}
	return 0
}

func (x *TestRequest) GetProtocol() string {
	if x != nil {
		return x.Protocol
	}
	return ""
}

func (x *TestRequest) GetReverse() bool {
	if x != nil {
		return x.Reverse
	}
	return false
}

func (x *TestRequest) GetBandwidth() uint64 {
	if x != nil {
		return x.Bandwidth
	}
	return 0
}

func (x *TestRequest) GetDuration() float64 {
	if x != nil {
		return x.Duration
	}
	return 0
}

func (x *TestRequest) GetParallel() uint32 {
	if x != nil {
		return x.Parallel
	}
	return 0
}

func (x *TestRequest) GetLength() uint32 {
	if x != nil {
		return x.Length
	}
	return 0
}

func (x *TestRequest) GetOmit() uint32 {
	if x != nil {
		return x.Omit
	}
	return 0
}

func (x *TestRequest) GetNoDelay() bool {
	if x != nil {
		return x.NoDelay
	}
	return false
}

func (x *TestRequest) GetSendBuffer() uint32 {
	if x != nil {
		return x.SendBuffer
	}
	return 0
}

func (x *TestRequest) GetReceiveBuffer() uint32 {
	if x != nil {
		return x.ReceiveBuffer
	}
	return 0
}

func (x *TestRequest) GetSendInterval() float64 {
	if x != nil {
		return x.SendInterval
	}
	return 0
}

// Test response with results
type TestResponse struct {
	state       protoimpl.MessageState `protogen:"open.v1"`
	Success     bool                   `protobuf:"varint,1,opt,name=success,proto3" json:"success,omitempty"`                           // Whether the test completed successfully
	Error       string                 `protobuf:"bytes,2,opt,name=error,proto3" json:"error,omitempty"`                                // Error message, if any
	ResultsJson string                 `protobuf:"bytes,3,opt,name=results_json,json=resultsJson,proto3" json:"results_json,omitempty"` // Full results in JSON format
	// Summary metrics
	Summary       *TestSummary `protobuf:"bytes,4,opt,name=summary,proto3" json:"summary,omitempty"`
	unknownFields protoimpl.UnknownFields
	sizeCache     protoimpl.SizeCache
}

func (x *TestResponse) Reset() {
	*x = TestResponse{}
	mi := &file_rperf_rperf_proto_msgTypes[1]
	ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
	ms.StoreMessageInfo(mi)
}

func (x *TestResponse) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*TestResponse) ProtoMessage() {}

func (x *TestResponse) ProtoReflect() protoreflect.Message {
	mi := &file_rperf_rperf_proto_msgTypes[1]
	if x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use TestResponse.ProtoReflect.Descriptor instead.
func (*TestResponse) Descriptor() ([]byte, []int) {
	return file_rperf_rperf_proto_rawDescGZIP(), []int{1}
}

func (x *TestResponse) GetSuccess() bool {
	if x != nil {
		return x.Success
	}
	return false
}

func (x *TestResponse) GetError() string {
	if x != nil {
		return x.Error
	}
	return ""
}

func (x *TestResponse) GetResultsJson() string {
	if x != nil {
		return x.ResultsJson
	}
	return ""
}

func (x *TestResponse) GetSummary() *TestSummary {
	if x != nil {
		return x.Summary
	}
	return nil
}

// Summary of test results
type TestSummary struct {
	state         protoimpl.MessageState `protogen:"open.v1"`
	Duration      float64                `protobuf:"fixed64,1,opt,name=duration,proto3" json:"duration,omitempty"`                                  // Test duration in seconds
	BytesSent     uint64                 `protobuf:"varint,2,opt,name=bytes_sent,json=bytesSent,proto3" json:"bytes_sent,omitempty"`                // Total bytes sent
	BytesReceived uint64                 `protobuf:"varint,3,opt,name=bytes_received,json=bytesReceived,proto3" json:"bytes_received,omitempty"`    // Total bytes received
	BitsPerSecond float64                `protobuf:"fixed64,4,opt,name=bits_per_second,json=bitsPerSecond,proto3" json:"bits_per_second,omitempty"` // Throughput in bits per second
	// UDP-specific fields
	PacketsSent     uint64  `protobuf:"varint,5,opt,name=packets_sent,json=packetsSent,proto3" json:"packets_sent,omitempty"`             // UDP packets sent
	PacketsReceived uint64  `protobuf:"varint,6,opt,name=packets_received,json=packetsReceived,proto3" json:"packets_received,omitempty"` // UDP packets received
	PacketsLost     uint64  `protobuf:"varint,7,opt,name=packets_lost,json=packetsLost,proto3" json:"packets_lost,omitempty"`             // UDP packets lost
	LossPercent     float64 `protobuf:"fixed64,8,opt,name=loss_percent,json=lossPercent,proto3" json:"loss_percent,omitempty"`            // Packet loss percentage
	JitterMs        float64 `protobuf:"fixed64,9,opt,name=jitter_ms,json=jitterMs,proto3" json:"jitter_ms,omitempty"`                     // Jitter in milliseconds
	unknownFields   protoimpl.UnknownFields
	sizeCache       protoimpl.SizeCache
}

func (x *TestSummary) Reset() {
	*x = TestSummary{}
	mi := &file_rperf_rperf_proto_msgTypes[2]
	ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
	ms.StoreMessageInfo(mi)
}

func (x *TestSummary) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*TestSummary) ProtoMessage() {}

func (x *TestSummary) ProtoReflect() protoreflect.Message {
	mi := &file_rperf_rperf_proto_msgTypes[2]
	if x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use TestSummary.ProtoReflect.Descriptor instead.
func (*TestSummary) Descriptor() ([]byte, []int) {
	return file_rperf_rperf_proto_rawDescGZIP(), []int{2}
}

func (x *TestSummary) GetDuration() float64 {
	if x != nil {
		return x.Duration
	}
	return 0
}

func (x *TestSummary) GetBytesSent() uint64 {
	if x != nil {
		return x.BytesSent
	}
	return 0
}

func (x *TestSummary) GetBytesReceived() uint64 {
	if x != nil {
		return x.BytesReceived
	}
	return 0
}

func (x *TestSummary) GetBitsPerSecond() float64 {
	if x != nil {
		return x.BitsPerSecond
	}
	return 0
}

func (x *TestSummary) GetPacketsSent() uint64 {
	if x != nil {
		return x.PacketsSent
	}
	return 0
}

func (x *TestSummary) GetPacketsReceived() uint64 {
	if x != nil {
		return x.PacketsReceived
	}
	return 0
}

func (x *TestSummary) GetPacketsLost() uint64 {
	if x != nil {
		return x.PacketsLost
	}
	return 0
}

func (x *TestSummary) GetLossPercent() float64 {
	if x != nil {
		return x.LossPercent
	}
	return 0
}

func (x *TestSummary) GetJitterMs() float64 {
	if x != nil {
		return x.JitterMs
	}
	return 0
}

// Status request (empty for now)
type StatusRequest struct {
	state         protoimpl.MessageState `protogen:"open.v1"`
	unknownFields protoimpl.UnknownFields
	sizeCache     protoimpl.SizeCache
}

func (x *StatusRequest) Reset() {
	*x = StatusRequest{}
	mi := &file_rperf_rperf_proto_msgTypes[3]
	ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
	ms.StoreMessageInfo(mi)
}

func (x *StatusRequest) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*StatusRequest) ProtoMessage() {}

func (x *StatusRequest) ProtoReflect() protoreflect.Message {
	mi := &file_rperf_rperf_proto_msgTypes[3]
	if x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use StatusRequest.ProtoReflect.Descriptor instead.
func (*StatusRequest) Descriptor() ([]byte, []int) {
	return file_rperf_rperf_proto_rawDescGZIP(), []int{3}
}

// Status response with service info
type StatusResponse struct {
	state         protoimpl.MessageState `protogen:"open.v1"`
	Available     bool                   `protobuf:"varint,1,opt,name=available,proto3" json:"available,omitempty"` // Whether the service is available
	Version       string                 `protobuf:"bytes,2,opt,name=version,proto3" json:"version,omitempty"`      // Version information
	Message       string                 `protobuf:"bytes,3,opt,name=message,proto3" json:"message,omitempty"`      // Additional status information
	unknownFields protoimpl.UnknownFields
	sizeCache     protoimpl.SizeCache
}

func (x *StatusResponse) Reset() {
	*x = StatusResponse{}
	mi := &file_rperf_rperf_proto_msgTypes[4]
	ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
	ms.StoreMessageInfo(mi)
}

func (x *StatusResponse) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*StatusResponse) ProtoMessage() {}

func (x *StatusResponse) ProtoReflect() protoreflect.Message {
	mi := &file_rperf_rperf_proto_msgTypes[4]
	if x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use StatusResponse.ProtoReflect.Descriptor instead.
func (*StatusResponse) Descriptor() ([]byte, []int) {
	return file_rperf_rperf_proto_rawDescGZIP(), []int{4}
}

func (x *StatusResponse) GetAvailable() bool {
	if x != nil {
		return x.Available
	}
	return false
}

func (x *StatusResponse) GetVersion() string {
	if x != nil {
		return x.Version
	}
	return ""
}

func (x *StatusResponse) GetMessage() string {
	if x != nil {
		return x.Message
	}
	return ""
}

var File_rperf_rperf_proto protoreflect.FileDescriptor

var file_rperf_rperf_proto_rawDesc = string([]byte{
	0x0a, 0x11, 0x72, 0x70, 0x65, 0x72, 0x66, 0x2f, 0x72, 0x70, 0x65, 0x72, 0x66, 0x2e, 0x70, 0x72,
	0x6f, 0x74, 0x6f, 0x12, 0x05, 0x72, 0x70, 0x65, 0x72, 0x66, 0x22, 0x88, 0x03, 0x0a, 0x0b, 0x54,
	0x65, 0x73, 0x74, 0x52, 0x65, 0x71, 0x75, 0x65, 0x73, 0x74, 0x12, 0x25, 0x0a, 0x0e, 0x74, 0x61,
	0x72, 0x67, 0x65, 0x74, 0x5f, 0x61, 0x64, 0x64, 0x72, 0x65, 0x73, 0x73, 0x18, 0x01, 0x20, 0x01,
	0x28, 0x09, 0x52, 0x0d, 0x74, 0x61, 0x72, 0x67, 0x65, 0x74, 0x41, 0x64, 0x64, 0x72, 0x65, 0x73,
	0x73, 0x12, 0x12, 0x0a, 0x04, 0x70, 0x6f, 0x72, 0x74, 0x18, 0x02, 0x20, 0x01, 0x28, 0x0d, 0x52,
	0x04, 0x70, 0x6f, 0x72, 0x74, 0x12, 0x1a, 0x0a, 0x08, 0x70, 0x72, 0x6f, 0x74, 0x6f, 0x63, 0x6f,
	0x6c, 0x18, 0x03, 0x20, 0x01, 0x28, 0x09, 0x52, 0x08, 0x70, 0x72, 0x6f, 0x74, 0x6f, 0x63, 0x6f,
	0x6c, 0x12, 0x18, 0x0a, 0x07, 0x72, 0x65, 0x76, 0x65, 0x72, 0x73, 0x65, 0x18, 0x04, 0x20, 0x01,
	0x28, 0x08, 0x52, 0x07, 0x72, 0x65, 0x76, 0x65, 0x72, 0x73, 0x65, 0x12, 0x1c, 0x0a, 0x09, 0x62,
	0x61, 0x6e, 0x64, 0x77, 0x69, 0x64, 0x74, 0x68, 0x18, 0x05, 0x20, 0x01, 0x28, 0x04, 0x52, 0x09,
	0x62, 0x61, 0x6e, 0x64, 0x77, 0x69, 0x64, 0x74, 0x68, 0x12, 0x1a, 0x0a, 0x08, 0x64, 0x75, 0x72,
	0x61, 0x74, 0x69, 0x6f, 0x6e, 0x18, 0x06, 0x20, 0x01, 0x28, 0x01, 0x52, 0x08, 0x64, 0x75, 0x72,
	0x61, 0x74, 0x69, 0x6f, 0x6e, 0x12, 0x1a, 0x0a, 0x08, 0x70, 0x61, 0x72, 0x61, 0x6c, 0x6c, 0x65,
	0x6c, 0x18, 0x07, 0x20, 0x01, 0x28, 0x0d, 0x52, 0x08, 0x70, 0x61, 0x72, 0x61, 0x6c, 0x6c, 0x65,
	0x6c, 0x12, 0x16, 0x0a, 0x06, 0x6c, 0x65, 0x6e, 0x67, 0x74, 0x68, 0x18, 0x08, 0x20, 0x01, 0x28,
	0x0d, 0x52, 0x06, 0x6c, 0x65, 0x6e, 0x67, 0x74, 0x68, 0x12, 0x12, 0x0a, 0x04, 0x6f, 0x6d, 0x69,
	0x74, 0x18, 0x09, 0x20, 0x01, 0x28, 0x0d, 0x52, 0x04, 0x6f, 0x6d, 0x69, 0x74, 0x12, 0x19, 0x0a,
	0x08, 0x6e, 0x6f, 0x5f, 0x64, 0x65, 0x6c, 0x61, 0x79, 0x18, 0x0a, 0x20, 0x01, 0x28, 0x08, 0x52,
	0x07, 0x6e, 0x6f, 0x44, 0x65, 0x6c, 0x61, 0x79, 0x12, 0x1f, 0x0a, 0x0b, 0x73, 0x65, 0x6e, 0x64,
	0x5f, 0x62, 0x75, 0x66, 0x66, 0x65, 0x72, 0x18, 0x0b, 0x20, 0x01, 0x28, 0x0d, 0x52, 0x0a, 0x73,
	0x65, 0x6e, 0x64, 0x42, 0x75, 0x66, 0x66, 0x65, 0x72, 0x12, 0x25, 0x0a, 0x0e, 0x72, 0x65, 0x63,
	0x65, 0x69, 0x76, 0x65, 0x5f, 0x62, 0x75, 0x66, 0x66, 0x65, 0x72, 0x18, 0x0c, 0x20, 0x01, 0x28,
	0x0d, 0x52, 0x0d, 0x72, 0x65, 0x63, 0x65, 0x69, 0x76, 0x65, 0x42, 0x75, 0x66, 0x66, 0x65, 0x72,
	0x12, 0x23, 0x0a, 0x0d, 0x73, 0x65, 0x6e, 0x64, 0x5f, 0x69, 0x6e, 0x74, 0x65, 0x72, 0x76, 0x61,
	0x6c, 0x18, 0x0d, 0x20, 0x01, 0x28, 0x01, 0x52, 0x0c, 0x73, 0x65, 0x6e, 0x64, 0x49, 0x6e, 0x74,
	0x65, 0x72, 0x76, 0x61, 0x6c, 0x22, 0x8f, 0x01, 0x0a, 0x0c, 0x54, 0x65, 0x73, 0x74, 0x52, 0x65,
	0x73, 0x70, 0x6f, 0x6e, 0x73, 0x65, 0x12, 0x18, 0x0a, 0x07, 0x73, 0x75, 0x63, 0x63, 0x65, 0x73,
	0x73, 0x18, 0x01, 0x20, 0x01, 0x28, 0x08, 0x52, 0x07, 0x73, 0x75, 0x63, 0x63, 0x65, 0x73, 0x73,
	0x12, 0x14, 0x0a, 0x05, 0x65, 0x72, 0x72, 0x6f, 0x72, 0x18, 0x02, 0x20, 0x01, 0x28, 0x09, 0x52,
	0x05, 0x65, 0x72, 0x72, 0x6f, 0x72, 0x12, 0x21, 0x0a, 0x0c, 0x72, 0x65, 0x73, 0x75, 0x6c, 0x74,
	0x73, 0x5f, 0x6a, 0x73, 0x6f, 0x6e, 0x18, 0x03, 0x20, 0x01, 0x28, 0x09, 0x52, 0x0b, 0x72, 0x65,
	0x73, 0x75, 0x6c, 0x74, 0x73, 0x4a, 0x73, 0x6f, 0x6e, 0x12, 0x2c, 0x0a, 0x07, 0x73, 0x75, 0x6d,
	0x6d, 0x61, 0x72, 0x79, 0x18, 0x04, 0x20, 0x01, 0x28, 0x0b, 0x32, 0x12, 0x2e, 0x72, 0x70, 0x65,
	0x72, 0x66, 0x2e, 0x54, 0x65, 0x73, 0x74, 0x53, 0x75, 0x6d, 0x6d, 0x61, 0x72, 0x79, 0x52, 0x07,
	0x73, 0x75, 0x6d, 0x6d, 0x61, 0x72, 0x79, 0x22, 0xc8, 0x02, 0x0a, 0x0b, 0x54, 0x65, 0x73, 0x74,
	0x53, 0x75, 0x6d, 0x6d, 0x61, 0x72, 0x79, 0x12, 0x1a, 0x0a, 0x08, 0x64, 0x75, 0x72, 0x61, 0x74,
	0x69, 0x6f, 0x6e, 0x18, 0x01, 0x20, 0x01, 0x28, 0x01, 0x52, 0x08, 0x64, 0x75, 0x72, 0x61, 0x74,
	0x69, 0x6f, 0x6e, 0x12, 0x1d, 0x0a, 0x0a, 0x62, 0x79, 0x74, 0x65, 0x73, 0x5f, 0x73, 0x65, 0x6e,
	0x74, 0x18, 0x02, 0x20, 0x01, 0x28, 0x04, 0x52, 0x09, 0x62, 0x79, 0x74, 0x65, 0x73, 0x53, 0x65,
	0x6e, 0x74, 0x12, 0x25, 0x0a, 0x0e, 0x62, 0x79, 0x74, 0x65, 0x73, 0x5f, 0x72, 0x65, 0x63, 0x65,
	0x69, 0x76, 0x65, 0x64, 0x18, 0x03, 0x20, 0x01, 0x28, 0x04, 0x52, 0x0d, 0x62, 0x79, 0x74, 0x65,
	0x73, 0x52, 0x65, 0x63, 0x65, 0x69, 0x76, 0x65, 0x64, 0x12, 0x26, 0x0a, 0x0f, 0x62, 0x69, 0x74,
	0x73, 0x5f, 0x70, 0x65, 0x72, 0x5f, 0x73, 0x65, 0x63, 0x6f, 0x6e, 0x64, 0x18, 0x04, 0x20, 0x01,
	0x28, 0x01, 0x52, 0x0d, 0x62, 0x69, 0x74, 0x73, 0x50, 0x65, 0x72, 0x53, 0x65, 0x63, 0x6f, 0x6e,
	0x64, 0x12, 0x21, 0x0a, 0x0c, 0x70, 0x61, 0x63, 0x6b, 0x65, 0x74, 0x73, 0x5f, 0x73, 0x65, 0x6e,
	0x74, 0x18, 0x05, 0x20, 0x01, 0x28, 0x04, 0x52, 0x0b, 0x70, 0x61, 0x63, 0x6b, 0x65, 0x74, 0x73,
	0x53, 0x65, 0x6e, 0x74, 0x12, 0x29, 0x0a, 0x10, 0x70, 0x61, 0x63, 0x6b, 0x65, 0x74, 0x73, 0x5f,
	0x72, 0x65, 0x63, 0x65, 0x69, 0x76, 0x65, 0x64, 0x18, 0x06, 0x20, 0x01, 0x28, 0x04, 0x52, 0x0f,
	0x70, 0x61, 0x63, 0x6b, 0x65, 0x74, 0x73, 0x52, 0x65, 0x63, 0x65, 0x69, 0x76, 0x65, 0x64, 0x12,
	0x21, 0x0a, 0x0c, 0x70, 0x61, 0x63, 0x6b, 0x65, 0x74, 0x73, 0x5f, 0x6c, 0x6f, 0x73, 0x74, 0x18,
	0x07, 0x20, 0x01, 0x28, 0x04, 0x52, 0x0b, 0x70, 0x61, 0x63, 0x6b, 0x65, 0x74, 0x73, 0x4c, 0x6f,
	0x73, 0x74, 0x12, 0x21, 0x0a, 0x0c, 0x6c, 0x6f, 0x73, 0x73, 0x5f, 0x70, 0x65, 0x72, 0x63, 0x65,
	0x6e, 0x74, 0x18, 0x08, 0x20, 0x01, 0x28, 0x01, 0x52, 0x0b, 0x6c, 0x6f, 0x73, 0x73, 0x50, 0x65,
	0x72, 0x63, 0x65, 0x6e, 0x74, 0x12, 0x1b, 0x0a, 0x09, 0x6a, 0x69, 0x74, 0x74, 0x65, 0x72, 0x5f,
	0x6d, 0x73, 0x18, 0x09, 0x20, 0x01, 0x28, 0x01, 0x52, 0x08, 0x6a, 0x69, 0x74, 0x74, 0x65, 0x72,
	0x4d, 0x73, 0x22, 0x0f, 0x0a, 0x0d, 0x53, 0x74, 0x61, 0x74, 0x75, 0x73, 0x52, 0x65, 0x71, 0x75,
	0x65, 0x73, 0x74, 0x22, 0x62, 0x0a, 0x0e, 0x53, 0x74, 0x61, 0x74, 0x75, 0x73, 0x52, 0x65, 0x73,
	0x70, 0x6f, 0x6e, 0x73, 0x65, 0x12, 0x1c, 0x0a, 0x09, 0x61, 0x76, 0x61, 0x69, 0x6c, 0x61, 0x62,
	0x6c, 0x65, 0x18, 0x01, 0x20, 0x01, 0x28, 0x08, 0x52, 0x09, 0x61, 0x76, 0x61, 0x69, 0x6c, 0x61,
	0x62, 0x6c, 0x65, 0x12, 0x18, 0x0a, 0x07, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x18, 0x02,
	0x20, 0x01, 0x28, 0x09, 0x52, 0x07, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x12, 0x18, 0x0a,
	0x07, 0x6d, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x18, 0x03, 0x20, 0x01, 0x28, 0x09, 0x52, 0x07,
	0x6d, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x32, 0x80, 0x01, 0x0a, 0x0c, 0x52, 0x50, 0x65, 0x72,
	0x66, 0x53, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65, 0x12, 0x34, 0x0a, 0x07, 0x52, 0x75, 0x6e, 0x54,
	0x65, 0x73, 0x74, 0x12, 0x12, 0x2e, 0x72, 0x70, 0x65, 0x72, 0x66, 0x2e, 0x54, 0x65, 0x73, 0x74,
	0x52, 0x65, 0x71, 0x75, 0x65, 0x73, 0x74, 0x1a, 0x13, 0x2e, 0x72, 0x70, 0x65, 0x72, 0x66, 0x2e,
	0x54, 0x65, 0x73, 0x74, 0x52, 0x65, 0x73, 0x70, 0x6f, 0x6e, 0x73, 0x65, 0x22, 0x00, 0x12, 0x3a,
	0x0a, 0x09, 0x47, 0x65, 0x74, 0x53, 0x74, 0x61, 0x74, 0x75, 0x73, 0x12, 0x14, 0x2e, 0x72, 0x70,
	0x65, 0x72, 0x66, 0x2e, 0x53, 0x74, 0x61, 0x74, 0x75, 0x73, 0x52, 0x65, 0x71, 0x75, 0x65, 0x73,
	0x74, 0x1a, 0x15, 0x2e, 0x72, 0x70, 0x65, 0x72, 0x66, 0x2e, 0x53, 0x74, 0x61, 0x74, 0x75, 0x73,
	0x52, 0x65, 0x73, 0x70, 0x6f, 0x6e, 0x73, 0x65, 0x22, 0x00, 0x42, 0x47, 0x5a, 0x45, 0x67, 0x69,
	0x74, 0x68, 0x75, 0x62, 0x2e, 0x63, 0x6f, 0x6d, 0x2f, 0x63, 0x61, 0x72, 0x76, 0x65, 0x72, 0x61,
	0x75, 0x74, 0x6f, 0x2f, 0x73, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65, 0x72, 0x61, 0x64, 0x61, 0x72,
	0x2f, 0x63, 0x6d, 0x64, 0x2f, 0x63, 0x68, 0x65, 0x63, 0x6b, 0x65, 0x72, 0x73, 0x2f, 0x72, 0x70,
	0x65, 0x72, 0x66, 0x2f, 0x73, 0x72, 0x63, 0x2f, 0x70, 0x72, 0x6f, 0x74, 0x6f, 0x2f, 0x72, 0x70,
	0x65, 0x72, 0x66, 0x62, 0x06, 0x70, 0x72, 0x6f, 0x74, 0x6f, 0x33,
})

var (
	file_rperf_rperf_proto_rawDescOnce sync.Once
	file_rperf_rperf_proto_rawDescData []byte
)

func file_rperf_rperf_proto_rawDescGZIP() []byte {
	file_rperf_rperf_proto_rawDescOnce.Do(func() {
		file_rperf_rperf_proto_rawDescData = protoimpl.X.CompressGZIP(unsafe.Slice(unsafe.StringData(file_rperf_rperf_proto_rawDesc), len(file_rperf_rperf_proto_rawDesc)))
	})
	return file_rperf_rperf_proto_rawDescData
}

var file_rperf_rperf_proto_msgTypes = make([]protoimpl.MessageInfo, 5)
var file_rperf_rperf_proto_goTypes = []any{
	(*TestRequest)(nil),    // 0: rperf.TestRequest
	(*TestResponse)(nil),   // 1: rperf.TestResponse
	(*TestSummary)(nil),    // 2: rperf.TestSummary
	(*StatusRequest)(nil),  // 3: rperf.StatusRequest
	(*StatusResponse)(nil), // 4: rperf.StatusResponse
}
var file_rperf_rperf_proto_depIdxs = []int32{
	2, // 0: rperf.TestResponse.summary:type_name -> rperf.TestSummary
	0, // 1: rperf.RPerfService.RunTest:input_type -> rperf.TestRequest
	3, // 2: rperf.RPerfService.GetStatus:input_type -> rperf.StatusRequest
	1, // 3: rperf.RPerfService.RunTest:output_type -> rperf.TestResponse
	4, // 4: rperf.RPerfService.GetStatus:output_type -> rperf.StatusResponse
	3, // [3:5] is the sub-list for method output_type
	1, // [1:3] is the sub-list for method input_type
	1, // [1:1] is the sub-list for extension type_name
	1, // [1:1] is the sub-list for extension extendee
	0, // [0:1] is the sub-list for field type_name
}

func init() { file_rperf_rperf_proto_init() }
func file_rperf_rperf_proto_init() {
	if File_rperf_rperf_proto != nil {
		return
	}
	type x struct{}
	out := protoimpl.TypeBuilder{
		File: protoimpl.DescBuilder{
			GoPackagePath: reflect.TypeOf(x{}).PkgPath(),
			RawDescriptor: unsafe.Slice(unsafe.StringData(file_rperf_rperf_proto_rawDesc), len(file_rperf_rperf_proto_rawDesc)),
			NumEnums:      0,
			NumMessages:   5,
			NumExtensions: 0,
			NumServices:   1,
		},
		GoTypes:           file_rperf_rperf_proto_goTypes,
		DependencyIndexes: file_rperf_rperf_proto_depIdxs,
		MessageInfos:      file_rperf_rperf_proto_msgTypes,
	}.Build()
	File_rperf_rperf_proto = out.File
	file_rperf_rperf_proto_goTypes = nil
	file_rperf_rperf_proto_depIdxs = nil
}
