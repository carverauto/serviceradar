/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package edgerecord

import (
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

// DecodeFrame enforces the raw frame and relational envelope ceilings before
// protobuf decoding. RecordBytes remains opaque; DecodeRecord owns its next stage.
// This is wire admission, not ValidateDeliveryFrame's semantic/authentication checks.
func DecodeFrame(raw []byte) (*edgev1.EdgeDeliveryFrameV1, error) {
	if err := ValidateFrameRawEnvelope(raw); err != nil {
		return nil, err
	}
	frame := &edgev1.EdgeDeliveryFrameV1{}
	if err := proto.Unmarshal(raw, frame); err != nil {
		return nil, ErrRecordDecode
	}
	if hasUnknownFields(frame) {
		return nil, ErrUnknownFields
	}
	return frame, nil
}

// DecodeClientMessage applies the edge ABI ceiling before any scan or decode,
// requires exactly one outer payload occurrence, and bounds a nested frame's
// original envelope before protobuf can collapse duplicate fields. A gRPC size
// setting is not a substitute for this wire boundary. Semantic lane/frame
// validation and record extraction remain separate stages.
func DecodeClientMessage(raw []byte) (*edgev1.EdgeRecordClientMessage, error) {
	if len(raw) > MaxClientMessageBytes {
		return nil, ErrClientMessageTooLarge
	}
	if err := validateClientRawEnvelope(raw); err != nil {
		return nil, err
	}
	message := &edgev1.EdgeRecordClientMessage{}
	if err := proto.Unmarshal(raw, message); err != nil {
		return nil, ErrRecordDecode
	}
	if hasUnknownFields(message) {
		return nil, ErrUnknownFields
	}
	return message, nil
}

func validateClientRawEnvelope(raw []byte) error {
	seen := false
	var frame []byte
	for len(raw) > 0 {
		field, kind, n := protowire.ConsumeTag(raw)
		if n < 0 || (field != 1 && field != 2) || kind != protowire.BytesType || seen {
			return ErrRecordDecode
		}
		body, consumed := protowire.ConsumeBytes(raw[n:])
		if consumed < 0 {
			return ErrRecordDecode
		}
		seen = true
		if field == 2 {
			frame = body
		}
		raw = raw[n+consumed:]
	}
	if !seen {
		return ErrRecordDecode
	}
	if frame != nil {
		return ValidateFrameRawEnvelope(frame)
	}
	return nil
}
