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

package netprobe

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"

	"github.com/carverauto/serviceradar/proto"
)

// The whole justification for keeping netprobe's termination enum separate from
// the wire enum is that this mapping stays total. Nothing about a Go switch
// enforces that -- a new netprobe value simply falls to `default` -- so the
// descriptor is walked instead of a hand-written list, which cannot drift from
// the proto by construction.
func TestCaptureSessionStateMappingIsTotal(t *testing.T) {
	values := netprobepb.CaptureTerminationReason(0).Descriptor().Values()
	require.Positive(t, values.Len(), "netprobe's enum descriptor must be readable")

	// Every value EXCEPT the proto3 default must map to something specific.
	// UNSPECIFIED maps to UNSPECIFIED on purpose: it means netprobe said
	// nothing, which is different from this build not understanding what it
	// said.
	for i := range values.Len() {
		value := values.Get(i)
		reason := netprobepb.CaptureTerminationReason(value.Number())
		mapped := CaptureSessionState(reason)

		if reason == netprobepb.CaptureTerminationReason_CAPTURE_TERMINATION_REASON_UNSPECIFIED {
			assert.Equal(t,
				proto.CaptureSessionState_CAPTURE_SESSION_STATE_UNSPECIFIED, mapped,
				"an unspecified reason must stay unspecified")

			continue
		}

		assert.NotEqualf(t,
			proto.CaptureSessionState_CAPTURE_SESSION_STATE_UNKNOWN_REASON, mapped,
			"netprobe reason %s has no mapping in CaptureSessionState; add one, or a capture "+
				"that ended for this reason will be recorded upstream as having ended for an "+
				"unknown one", value.Name())

		assert.NotEqualf(t,
			proto.CaptureSessionState_CAPTURE_SESSION_STATE_UNSPECIFIED, mapped,
			"netprobe reason %s maps to UNSPECIFIED, which is indistinguishable from netprobe "+
				"not having said anything", value.Name())
	}
}

// Every mapped reason must land on a DISTINCT wire value. A mapping that is
// total but collapses two reasons into one passes the test above while losing
// the difference between "the operator stopped it" and "the client vanished" --
// which is the difference an audit trail exists to record.
func TestCaptureSessionStateMappingIsInjective(t *testing.T) {
	values := netprobepb.CaptureTerminationReason(0).Descriptor().Values()
	seen := make(map[proto.CaptureSessionState]string, values.Len())

	for i := range values.Len() {
		value := values.Get(i)
		mapped := CaptureSessionState(netprobepb.CaptureTerminationReason(value.Number()))

		if previous, collision := seen[mapped]; collision {
			t.Errorf("netprobe reasons %s and %s both map to %s; a capture stopped by one "+
				"would be indistinguishable from one stopped by the other",
				previous, value.Name(), mapped)
		}

		seen[mapped] = string(value.Name())
	}
}

// A value netprobe might send that this build has never heard of -- the
// new-sidecar/old-agent skew that the add-on's base-agent FLOOR makes a
// supported steady state, not a rollout transient.
func TestAnUnrecognisedReasonIsVisibleRatherThanFlattened(t *testing.T) {
	// Deliberately outside the enum's current range.
	future := netprobepb.CaptureTerminationReason(9999)

	assert.Equal(t,
		proto.CaptureSessionState_CAPTURE_SESSION_STATE_UNKNOWN_REASON,
		CaptureSessionState(future),
		"an unmapped reason must be reported as unknown, not as unspecified: upstream cannot "+
			"tell a version skew from a netprobe that declined to say why a capture ended")
}
