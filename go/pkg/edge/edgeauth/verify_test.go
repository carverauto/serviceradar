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

package edgeauth

import (
	"errors"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func subject() Subject {
	return Subject{
		InstallationID: []byte("install-id-16byt"),
		NetworkScopeID: []byte("scope-id-16bytes"),
		AgentID:        []byte("agent-id-16bytes"),
		GatewayID:      []byte("gw-id-16bytes!!!"),
		PartitionID:    7,
	}
}

func okFrame() *edgev1.EdgeResultFrame {
	epoch := uint64(5)
	return &edgev1.EdgeResultFrame{
		NetworkScopeId:    []byte("scope-id-16bytes"),
		EventId:           []byte("event-id-16bytes"),
		PayloadSha256:     []byte("sha256-payload-digest-32bytes!!!"),
		AssignmentEpoch:   &epoch,
		AuthorizationKind: edgev1.EdgeResultAuthorizationKind_EDGE_RESULT_AUTHORIZATION_KIND_SWEEP_ASSIGNMENT,
	}
}

func okCap() Capability {
	return Capability{
		Kind:              edgev1.EdgeResultAuthorizationKind_EDGE_RESULT_AUTHORIZATION_KIND_SWEEP_ASSIGNMENT,
		NetworkScopeID:    []byte("scope-id-16bytes"),
		AgentID:           []byte("agent-id-16bytes"),
		AssignmentEpoch:   5,
		NotBeforeUnixNano: 1000,
		NotAfterUnixNano:  9000,
	}
}

func TestVerifyDeliveryHappyPath(t *testing.T) {
	d, err := VerifyDelivery(subject(), okFrame(), okCap(), 5000)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if d.AuditOnly {
		t.Fatal("current-epoch frame must not be audit-only")
	}
}

func TestVerifyRejectsScopeMismatch(t *testing.T) {
	f := okFrame()
	f.NetworkScopeId = []byte("other-scope-1616")
	if _, err := VerifyDelivery(subject(), f, okCap(), 5000); !errors.Is(err, ErrScopeMismatch) {
		t.Fatalf("scope = %v, want ErrScopeMismatch", err)
	}
}

func TestVerifyRejectsIdentityMismatch(t *testing.T) {
	c := okCap()
	c.AgentID = []byte("OTHER-agent-1616")
	if _, err := VerifyDelivery(subject(), okFrame(), c, 5000); !errors.Is(err, ErrIdentityMismatch) {
		t.Fatalf("identity = %v, want ErrIdentityMismatch", err)
	}
}

func TestVerifyRejectsAuthKindMismatch(t *testing.T) {
	c := okCap()
	c.Kind = edgev1.EdgeResultAuthorizationKind_EDGE_RESULT_AUTHORIZATION_KIND_SCHEDULED_CHECK
	if _, err := VerifyDelivery(subject(), okFrame(), c, 5000); !errors.Is(err, ErrAuthKindMismatch) {
		t.Fatalf("auth kind = %v, want ErrAuthKindMismatch", err)
	}
}

func TestVerifyRejectsExpiredCapability(t *testing.T) {
	if _, err := VerifyDelivery(subject(), okFrame(), okCap(), 999); !errors.Is(err, ErrCapabilityExpired) {
		t.Fatalf("before window = %v, want ErrCapabilityExpired", err)
	}
	if _, err := VerifyDelivery(subject(), okFrame(), okCap(), 9001); !errors.Is(err, ErrCapabilityExpired) {
		t.Fatalf("after window = %v, want ErrCapabilityExpired", err)
	}
}

func TestVerifyRejectsNewerEpoch(t *testing.T) {
	f := okFrame()
	newer := uint64(6)
	f.AssignmentEpoch = &newer
	if _, err := VerifyDelivery(subject(), f, okCap(), 5000); !errors.Is(err, ErrEpochConflict) {
		t.Fatalf("newer epoch = %v, want ErrEpochConflict", err)
	}
}

// A stale-epoch frame is rejected unless a matching event-bound delivery
// capability is presented, in which case it is admitted audit-only.
func TestVerifyStaleEpochReplay(t *testing.T) {
	f := okFrame()
	stale := uint64(4)
	f.AssignmentEpoch = &stale

	// No event binding -> rejected.
	if _, err := VerifyDelivery(subject(), f, okCap(), 5000); !errors.Is(err, ErrStaleReplayUnbound) {
		t.Fatalf("unbound stale replay = %v, want ErrStaleReplayUnbound", err)
	}

	// Event-bound delivery capability -> admitted audit-only.
	c := okCap()
	c.AssignmentEpoch = 5
	c.IsDelivery = true
	c.BoundEventID = f.GetEventId()
	c.BoundPayloadSHA256 = f.GetPayloadSha256()
	d, err := VerifyDelivery(subject(), f, c, 5000)
	if err != nil {
		t.Fatalf("bound stale replay: %v", err)
	}
	if !d.AuditOnly {
		t.Fatal("stale-epoch replay must be admitted audit-only")
	}

	// Wrong event binding -> rejected.
	c.BoundEventID = []byte("WRONG-event-1616")
	if _, err := VerifyDelivery(subject(), f, c, 5000); !errors.Is(err, ErrStaleReplayUnbound) {
		t.Fatalf("mismatched event binding = %v, want ErrStaleReplayUnbound", err)
	}
}
