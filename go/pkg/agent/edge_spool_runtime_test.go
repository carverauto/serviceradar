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

package agent

import (
	"errors"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errTestSpoolOpen     = errors.New("spool: mkdir: permission denied")
	errTestBudgetRefused = errors.New("capacity leaves no ordinary space")
)

// Both hellos carry the spool status, so core can show an agent whose spool did
// not open as spool_unavailable on whichever transport it reconnects over.
func TestHellosReportTheEdgeSpoolStatus(t *testing.T) {
	loop := NewPushLoop(&Server{config: &ServerConfig{}}, nil, 0, logger.NewTestLogger())
	loop.hostInventory = func() []hostInterface { return nil }
	loop.hostTLSFingerprints = func() []*proto.HostTlsFingerprint { return nil }
	loop.SetEdgeSpoolStatus(errTestSpoolOpen)

	stream := &fakeControlStreamClient{}
	if err := loop.sendControlHello(newControlStreamSender(stream)); err != nil {
		t.Fatal(err)
	}
	if len(stream.sent) == 0 || stream.sent[0].GetHello() == nil {
		t.Fatal("control stream did not send an initial hello")
	}

	for transport, got := range map[string]*proto.EdgeRecordSpoolStatus{
		"control":    stream.sent[0].GetHello().GetEdgeRecordSpool(),
		"enrollment": loop.buildEnrollmentHelloRequest().GetEdgeRecordSpool(),
	} {
		if got == nil || got.GetAvailable() || got.GetError() != "spool: mkdir: permission denied" {
			t.Errorf("%s hello spool status = %v, want unavailable with the open error", transport, got)
		}
	}

	loop.SetEdgeSpoolStatus(nil)
	if got := loop.buildEnrollmentHelloRequest().GetEdgeRecordSpool(); !got.GetAvailable() || got.GetError() != "" {
		t.Errorf("open spool status = %v, want available", got)
	}
}

// The config's budget is applied once per change; zero (a core that predates
// the setting) and a refused budget leave the running budget in place.
func TestConfigSpoolBudgetIsAppliedOnChange(t *testing.T) {
	loop := NewPushLoop(&Server{config: &ServerConfig{}}, nil, 0, logger.NewTestLogger())
	var applied []uint64
	refuse := false
	loop.SetEdgeSpoolBudget(func(maxBytes uint64) error {
		if refuse {
			return errTestBudgetRefused
		}
		applied = append(applied, maxBytes)
		return nil
	})

	for _, budget := range []uint64{256 << 20, 256 << 20, 0, 1 << 30} {
		loop.applyEdgeSpoolBudget(&proto.AgentConfigResponse{EdgeSpoolMaxBytes: budget})
	}
	refuse = true
	loop.applyEdgeSpoolBudget(&proto.AgentConfigResponse{EdgeSpoolMaxBytes: 1 << 20})
	refuse = false
	loop.applyEdgeSpoolBudget(&proto.AgentConfigResponse{EdgeSpoolMaxBytes: 1 << 30})

	want := []uint64{256 << 20, 1 << 30}
	if len(applied) != len(want) || applied[0] != want[0] || applied[1] != want[1] {
		t.Fatalf("applied budgets = %v, want %v", applied, want)
	}
}
