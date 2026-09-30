package main

import (
	"encoding/binary"
	"errors"
	"math"
)

// A minimal protobuf wire decoder for the few device-local messages the
// plugin reads. Message layouts are written from field numbers alone; no
// vendor .proto file is vendored. Unknown fields are skipped, so a newer
// device that adds fields still decodes.

const (
	wireVarint  = 0
	wireFixed64 = 1
	wireBytes   = 2
	wireFixed32 = 5
)

var errProtoTruncated = errors.New("protobuf message truncated")

// protoField is one decoded field occurrence.
type protoField struct {
	num   uint64
	wire  int
	value uint64 // varint, fixed32 and fixed64 payloads
	bytes []byte // length-delimited payload
}

func (f protoField) float32() float32 { return math.Float32frombits(uint32(f.value)) }
func (f protoField) float64() float64 { return math.Float64frombits(f.value) }
func (f protoField) bool() bool       { return f.value != 0 }
func (f protoField) int32() int32     { return int32(f.value) }

// protoFields decodes the top level of one message.
func protoFields(msg []byte) ([]protoField, error) {
	var out []protoField
	for len(msg) > 0 {
		key, n := binary.Uvarint(msg)
		if n <= 0 {
			return nil, errProtoTruncated
		}
		msg = msg[n:]
		f := protoField{num: key >> 3, wire: int(key & 7)}
		switch f.wire {
		case wireVarint:
			v, n := binary.Uvarint(msg)
			if n <= 0 {
				return nil, errProtoTruncated
			}
			f.value, msg = v, msg[n:]
		case wireFixed64:
			if len(msg) < 8 {
				return nil, errProtoTruncated
			}
			f.value, msg = binary.LittleEndian.Uint64(msg), msg[8:]
		case wireFixed32:
			if len(msg) < 4 {
				return nil, errProtoTruncated
			}
			f.value, msg = uint64(binary.LittleEndian.Uint32(msg)), msg[4:]
		case wireBytes:
			l, n := binary.Uvarint(msg)
			if n <= 0 || uint64(len(msg)-n) < l {
				return nil, errProtoTruncated
			}
			f.bytes, msg = msg[n:n+int(l)], msg[n+int(l):]
		default:
			return nil, errors.New("unsupported protobuf wire type")
		}
		out = append(out, f)
	}
	return out, nil
}

// protoAppendEmptyMessage appends field num carrying an empty submessage,
// which is how a oneof member with no fields is selected.
func protoAppendEmptyMessage(out []byte, num uint64) []byte {
	out = binary.AppendUvarint(out, num<<3|wireBytes)
	return binary.AppendUvarint(out, 0)
}
