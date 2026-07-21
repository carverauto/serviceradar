/*
 * Copyright 2025 Carver Automation Corporation.
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

package agent

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
)

func TestNormalizeAdhocTargets(t *testing.T) {
	t.Parallel()

	got := normalizeAdhocTargets([]string{" 10.0.0.1 ", "10.0.0.1", "", "10.0.0.2", "  "})
	want := []string{"10.0.0.1", "10.0.0.2"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("normalizeAdhocTargets = %v, want %v", got, want)
	}
}

func TestDedupePorts(t *testing.T) {
	t.Parallel()

	got := dedupePorts([]int{22, 22, 0, 80, 70000, -1, 443})
	want := []int{22, 80, 443}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("dedupePorts = %v, want %v", got, want)
	}
}

func TestAdhocModeSet(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name              string
		modes             []string
		icmp, tcp, mtrSet bool
	}{
		{"icmp only", []string{"icmp"}, true, false, false},
		{"tcp connect alias", []string{"tcp_connect"}, false, true, false},
		{"all three", []string{"icmp", "TCP", "mtr"}, true, true, true},
		{"unknown ignored", []string{"udp", "arp"}, false, false, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			icmp, tcp, mtrSet := adhocModeSet(tt.modes)
			if icmp != tt.icmp || tcp != tt.tcp || mtrSet != tt.mtrSet {
				t.Fatalf("adhocModeSet(%v) = (%v,%v,%v), want (%v,%v,%v)",
					tt.modes, icmp, tcp, mtrSet, tt.icmp, tt.tcp, tt.mtrSet)
			}
		})
	}
}

func TestAdhocProgressPercent(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		done, total int
		want        int32
	}{
		"zero total": {0, 0, 100},
		"half":       {5, 10, 50},
		"over caps":  {12, 10, 100},
		"quarter":    {1, 4, 25},
	}
	for name, c := range cases {
		if got := adhocProgressPercent(c.done, c.total); got != c.want {
			t.Errorf("%s: adhocProgressPercent(%d,%d) = %d, want %d", name, c.done, c.total, got, c.want)
		}
	}
}

func TestBuildAdhocMTRRow(t *testing.T) {
	t.Parallel()

	// reached, with hops -> available + response_ms from last hop avg + trace attached
	trace := &mtr.TraceResult{
		Target:        "10.0.0.1",
		TargetReached: true,
		Hops:          []mtr.HopSnapshot{{HopNumber: 1, AvgUs: 500}, {HopNumber: 2, AvgUs: 2500}},
	}
	row := buildAdhocMTRRow("10.0.0.1", trace, nil)
	if !row.Available || row.Mode != "mtr" || row.Trace == nil {
		t.Fatalf("reached row unexpected: %+v", row)
	}
	if row.ResponseMs != 2.5 {
		t.Fatalf("ResponseMs = %v, want 2.5", row.ResponseMs)
	}

	// error -> Error set, not available
	if r := buildAdhocMTRRow("h", nil, context.DeadlineExceeded); r.Available || r.Error == "" {
		t.Fatalf("error row unexpected: %+v", r)
	}

	// nil trace, no error -> error message
	if r := buildAdhocMTRRow("h", nil, nil); r.Error == "" {
		t.Fatalf("nil-trace row should carry an error")
	}

	// not reached -> not available but trace retained
	notReached := &mtr.TraceResult{Target: "h", TargetReached: false}
	if r := buildAdhocMTRRow("h", notReached, nil); r.Available || r.Trace == nil {
		t.Fatalf("not-reached row unexpected: %+v", r)
	}
}

func TestAdhocMTROptions(t *testing.T) {
	t.Parallel()

	opts := adhocMTROptions("example.com", adhocScanPayload{MTRProtocol: "tcp", MTRMaxHops: 12})
	if opts.Target != "example.com" {
		t.Fatalf("Target = %q", opts.Target)
	}
	if opts.MaxHops != 12 {
		t.Fatalf("MaxHops = %d, want 12", opts.MaxHops)
	}
	if opts.Protocol != mtr.ParseProtocol("tcp") {
		t.Fatalf("Protocol not parsed from payload")
	}
}

func TestHandleAdhocScanValidation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		payload     adhocScanPayload
		wantMessage string
	}{
		{
			name:        "missing targets",
			payload:     adhocScanPayload{Modes: []string{"icmp"}},
			wantMessage: "missing targets",
		},
		{
			name:        "no valid modes",
			payload:     adhocScanPayload{Targets: []string{"10.0.0.1"}, Modes: []string{"udp"}},
			wantMessage: "no valid scan modes requested",
		},
		{
			name:        "tcp without ports",
			payload:     adhocScanPayload{Targets: []string{"10.0.0.1"}, Modes: []string{"tcp"}},
			wantMessage: "tcp mode requires at least one port",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			stream := &fakeControlStreamClient{}
			sender := newControlStreamSender(stream)
			loop := &PushLoop{}

			body, err := json.Marshal(tt.payload)
			if err != nil {
				t.Fatalf("marshal payload: %v", err)
			}

			loop.handleAdhocScan(context.Background(), &proto.CommandRequest{
				CommandId:   "cmd-1",
				CommandType: commandTypeAdhocScan,
				PayloadJson: body,
			}, sender)

			if len(stream.sent) != 1 {
				t.Fatalf("expected exactly one response, got %d", len(stream.sent))
			}
			res := stream.sent[0].GetCommandResult()
			if res == nil {
				t.Fatalf("expected a CommandResult, got %+v", stream.sent[0])
			}
			if res.GetSuccess() {
				t.Fatalf("expected failure result for %s", tt.name)
			}
			if res.GetMessage() != tt.wantMessage {
				t.Fatalf("message = %q, want %q", res.GetMessage(), tt.wantMessage)
			}
		})
	}
}
