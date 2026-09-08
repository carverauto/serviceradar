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
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"

	"github.com/carverauto/serviceradar/proto"
)

// CaptureSessionState translates netprobe's IPC termination reason into the
// agent-to-gateway wire enum.
//
// The two enums are deliberately separate rather than one shared import.
// netprobe ships independently of the agent: its add-on manifest declares a
// base-agent FLOOR (">=1.2.0"), not a pin, so a new agent talking to an older
// netprobe is a supported steady state rather than a rollout transient. Sharing
// one enum across both hops would make every netprobe proto change a wire change
// for the gateway and core too.
//
// The cost of separating them is this function, and the risk is that it silently
// falls behind. A netprobe reason with no mapping here would arrive upstream as
// UNSPECIFIED -- indistinguishable from "netprobe did not say" -- which is how a
// capture that hit its byte cap gets recorded as having ended for no reason.
//
// Two things prevent that. Unmapped values return UNKNOWN_REASON rather than
// UNSPECIFIED, so a skew is visible in the audit record instead of being
// flattened into the default; and TestCaptureSessionStateMappingIsTotal walks
// netprobe's own enum descriptor and fails when a new value appears here without
// a mapping, so the gap is caught at build time rather than in an incident.
func CaptureSessionState(reason netprobepb.CaptureTerminationReason) proto.CaptureSessionState {
	switch reason {
	case netprobepb.CaptureTerminationReason_CAPTURE_TERMINATION_REASON_DURATION_CAP:
		return proto.CaptureSessionState_CAPTURE_SESSION_STATE_DURATION_CAP
	case netprobepb.CaptureTerminationReason_CAPTURE_TERMINATION_REASON_BYTE_CAP:
		return proto.CaptureSessionState_CAPTURE_SESSION_STATE_BYTE_CAP
	case netprobepb.CaptureTerminationReason_CAPTURE_TERMINATION_REASON_CLIENT_CANCEL:
		return proto.CaptureSessionState_CAPTURE_SESSION_STATE_CLIENT_CANCEL
	case netprobepb.CaptureTerminationReason_CAPTURE_TERMINATION_REASON_AGENT_DISCONNECT:
		return proto.CaptureSessionState_CAPTURE_SESSION_STATE_AGENT_DISCONNECT
	case netprobepb.CaptureTerminationReason_CAPTURE_TERMINATION_REASON_FILTER_ERROR:
		return proto.CaptureSessionState_CAPTURE_SESSION_STATE_FILTER_ERROR
	case netprobepb.CaptureTerminationReason_CAPTURE_TERMINATION_REASON_INTERFACE_DOWN:
		return proto.CaptureSessionState_CAPTURE_SESSION_STATE_INTERFACE_DOWN
	case netprobepb.CaptureTerminationReason_CAPTURE_TERMINATION_REASON_UNSPECIFIED:
		// netprobe genuinely said nothing. Distinct from a value this build
		// cannot map: it means the terminal block carried no reason, which is
		// what netprobe emits when it could not determine one.
		return proto.CaptureSessionState_CAPTURE_SESSION_STATE_UNSPECIFIED
	default:
		return proto.CaptureSessionState_CAPTURE_SESSION_STATE_UNKNOWN_REASON
	}
}
