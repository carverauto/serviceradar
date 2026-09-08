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

package edgev1_test

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

func TestLaneHandshakeBoundsCorpus(t *testing.T) {
	control := &edgev1.EdgeRecordLaneOpen{
		RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		SpoolId:      uuidv7(1), SequenceBase: 1, FirstUnresolvedSequence: 1, SessionNonce: uuidv7(2),
		RequestedByteCredits: 100, RequestedFrameCredits: 10,
	}
	var manifest strings.Builder
	emit := func(name string, accepted bool, req *edgev1.EdgeRecordLaneOpen, ack *edgev1.EdgeRecordLaneOpenAck) {
		t.Helper()
		requestFile := "lane_bound_" + name + "_request.bin"
		raw := golden(t, requestFile, req)
		decoded := &edgev1.EdgeRecordLaneOpen{}
		if err := proto.Unmarshal(raw, decoded); err != nil {
			t.Fatal(err)
		}
		err := edgerecord.ValidateLaneOpen(decoded)
		ackFile := "-"
		if ack != nil {
			ackFile = "lane_bound_" + name + "_ack.bin"
			ackRaw := golden(t, ackFile, ack)
			decodedAck := &edgev1.EdgeRecordLaneOpenAck{}
			if err := proto.Unmarshal(ackRaw, decodedAck); err != nil {
				t.Fatal(err)
			}
			err = edgerecord.ValidateLaneOpenAck(decodedAck, decoded)
		}
		if (err == nil) != accepted {
			t.Fatalf("%s accept=%v got %v", name, accepted, err)
		}
		fmt.Fprintf(&manifest, "%s %s %s %t\n", name, requestFile, ackFile, accepted)
	}
	emit("request_control", true, control, nil)
	for _, tc := range []struct {
		name     string
		accepted bool
		change   func(*edgev1.EdgeRecordLaneOpen)
	}{
		{"nonce_below", false, func(r *edgev1.EdgeRecordLaneOpen) { r.SessionNonce = bytes.Repeat([]byte{1}, 15) }},
		{"nonce_min", true, func(r *edgev1.EdgeRecordLaneOpen) { r.SessionNonce = bytes.Repeat([]byte{1}, 16) }},
		{"nonce_max", true, func(r *edgev1.EdgeRecordLaneOpen) { r.SessionNonce = bytes.Repeat([]byte{1}, 64) }},
		{"nonce_over", false, func(r *edgev1.EdgeRecordLaneOpen) { r.SessionNonce = bytes.Repeat([]byte{1}, 65) }},
		{"bytes_zero", false, func(r *edgev1.EdgeRecordLaneOpen) { r.RequestedByteCredits = 0 }},
		{"bytes_cap", true, func(r *edgev1.EdgeRecordLaneOpen) { r.RequestedByteCredits = 1073741824 }},
		{"bytes_over", false, func(r *edgev1.EdgeRecordLaneOpen) { r.RequestedByteCredits = 1073741825 }},
		{"frames_zero", false, func(r *edgev1.EdgeRecordLaneOpen) { r.RequestedFrameCredits = 0 }},
		{"frames_cap", true, func(r *edgev1.EdgeRecordLaneOpen) { r.RequestedFrameCredits = 1048576 }},
		{"frames_over", false, func(r *edgev1.EdgeRecordLaneOpen) { r.RequestedFrameCredits = 1048577 }},
		{"spool", false, func(r *edgev1.EdgeRecordLaneOpen) { r.SpoolId = nil }},
		{"base", false, func(r *edgev1.EdgeRecordLaneOpen) { r.SequenceBase = 0 }},
		{"unresolved", false, func(r *edgev1.EdgeRecordLaneOpen) { r.FirstUnresolvedSequence = 0 }},
		{"route", false, func(r *edgev1.EdgeRecordLaneOpen) { r.RouteProfile = 0 }},
		{"class", false, func(r *edgev1.EdgeRecordLaneOpen) { r.TrafficClass = 0 }},
		{"unknown", false, func(r *edgev1.EdgeRecordLaneOpen) { r.ProtoReflect().SetUnknown([]byte{160, 6, 1}) }},
	} {
		req := proto.Clone(control).(*edgev1.EdgeRecordLaneOpen)
		tc.change(req)
		emit(tc.name, tc.accepted, req, nil)
	}

	for _, tc := range []struct {
		name     string
		accepted bool
		change   func(*edgev1.EdgeRecordLaneOpenAck, *edgev1.EdgeRecordLaneOpen)
	}{
		{"grant_bytes_equal", true, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) {
			a.GrantedByteCredits = r.RequestedByteCredits
		}},
		{"grant_bytes_inside", true, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) {
			a.GrantedByteCredits = r.RequestedByteCredits - 1
		}},
		{"grant_bytes_zero", false, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) { a.GrantedByteCredits = 0 }},
		{"grant_bytes_over", false, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) {
			a.GrantedByteCredits = r.RequestedByteCredits + 1
		}},
		{"grant_frames_equal", true, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) {
			a.GrantedFrameCredits = r.RequestedFrameCredits
		}},
		{"grant_frames_inside", true, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) {
			a.GrantedFrameCredits = r.RequestedFrameCredits - 1
		}},
		{"grant_frames_zero", false, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) { a.GrantedFrameCredits = 0 }},
		{"grant_frames_over", false, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) {
			a.GrantedFrameCredits = r.RequestedFrameCredits + 1
		}},
		{"ack_spool", false, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) { a.SpoolId = uuidv7(3) }},
		{"ack_nonce", false, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) { a.SessionNonce = uuidv7(3) }},
		{"ack_route", false, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) { a.RouteProfile = 0 }},
		{"ack_class", false, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) { a.TrafficClass = 0 }},
		{"ack_unknown", false, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) {
			a.ProtoReflect().SetUnknown([]byte{160, 6, 1})
		}},
		{"ack_invalid_request", false, func(a *edgev1.EdgeRecordLaneOpenAck, r *edgev1.EdgeRecordLaneOpen) {
			r.RequestedByteCredits = 1073741825
		}},
	} {
		req := proto.Clone(control).(*edgev1.EdgeRecordLaneOpen)
		ack := &edgev1.EdgeRecordLaneOpenAck{SpoolId: req.SpoolId, SessionNonce: req.SessionNonce, RouteProfile: req.RouteProfile, TrafficClass: req.TrafficClass, GrantedByteCredits: 50, GrantedFrameCredits: 5}
		tc.change(ack, req)
		emit(tc.name, tc.accepted, req, ack)
	}
	goldenText(t, "lane_bounds_corpus.txt", manifest.String())
}
