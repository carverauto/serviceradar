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

// Package streamroute is the installation-local JetStream routing map shared by
// gateways and consumers (task 4.1). It defines the fixed, versioned subject
// space for the sweep-bulk, sweep-interactive, MTR-bulk, MTR-interactive, and
// recovery-control lanes over 64 stable logical partitions, a class-preserving
// DLQ subject per lane, and a complete, non-overlapping (lane, partition) ->
// physical stream map. Bulk and interactive lanes resolve to disjoint physical
// streams so they never share capacity. All routing is deterministic and
// derivable from trusted identity alone -- no broker-account prefix, no
// cross-account mirror -- so a gateway and a consumer independently compute the
// same subject for the same frame. This package holds no NATS I/O.
package streamroute

import (
	"fmt"
	"hash/fnv"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	// NumPartitions is the fixed count of stable logical data/DLQ partitions.
	NumPartitions = 64
	// SubjectVersion is the versioned hash/namespace revision baked into every
	// subject, so a subject-scheme change is an explicit, coordinated bump.
	SubjectVersion = 1
	// subjectRoot is the installation-local root; it carries no customer/account
	// prefix (single-deployment).
	subjectRoot = "sr.edge.v1"
)

// ErrUnroutableLane is returned for a lane kind that has no defined route
// (unspecified).
var ErrUnroutableLane = fmt.Errorf("streamroute: lane kind has no route")

// laneToken returns the stable subject token for a lane kind, and false for an
// unroutable lane.
func laneToken(lane edgev1.EdgeResultLaneKind) (string, bool) {
	switch lane {
	case edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_BULK:
		return "sweep.bulk", true
	case edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_INTERACTIVE:
		return "sweep.interactive", true
	case edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_MTR_BULK:
		return "mtr.bulk", true
	case edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_MTR_INTERACTIVE:
		return "mtr.interactive", true
	case edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_RECOVERY_CONTROL:
		return "recovery", true
	default:
		return "", false
	}
}

// streamToken returns the physical-stream token for a lane kind. Bulk and
// interactive resolve to disjoint tokens so they never share a physical stream.
func streamToken(lane edgev1.EdgeResultLaneKind) (string, bool) {
	// The per-lane subject token already distinguishes bulk/interactive and
	// sweep/MTR, so the stream token mirrors it: five disjoint physical streams.
	return laneToken(lane)
}

// Partition maps a routing key (typically the signed network_scope_id, or the
// execution id when scope is absent) to a stable partition in [0, NumPartitions).
// The mapping is deterministic and installation-local. An empty key maps to
// partition 0 rather than erroring, so a frame is always routable.
func Partition(key []byte) uint32 {
	if len(key) == 0 {
		return 0
	}
	h := fnv.New32a()
	_, _ = h.Write(key)
	return h.Sum32() % NumPartitions
}

// DataSubject returns the primary data subject for a lane and partition, e.g.
// "sr.edge.v1.sweep.bulk.p07.v1".
func DataSubject(lane edgev1.EdgeResultLaneKind, partition uint32) (string, error) {
	tok, ok := laneToken(lane)
	if !ok {
		return "", ErrUnroutableLane
	}
	if partition >= NumPartitions {
		return "", fmt.Errorf("streamroute: partition %d out of range", partition)
	}
	return fmt.Sprintf("%s.%s.p%02d.v%d", subjectRoot, tok, partition, SubjectVersion), nil
}

// DLQSubject returns the class-preserving dead-letter subject for a lane and
// partition. It is a distinct namespace from the data subject so poison never
// lands on the live data stream.
func DLQSubject(lane edgev1.EdgeResultLaneKind, partition uint32) (string, error) {
	tok, ok := laneToken(lane)
	if !ok {
		return "", ErrUnroutableLane
	}
	if partition >= NumPartitions {
		return "", fmt.Errorf("streamroute: partition %d out of range", partition)
	}
	return fmt.Sprintf("%s.dlq.%s.p%02d.v%d", subjectRoot, tok, partition, SubjectVersion), nil
}

// PhysicalStream returns the physical data-stream name for a lane. Bulk and
// interactive (and sweep and MTR) are disjoint streams.
func PhysicalStream(lane edgev1.EdgeResultLaneKind) (string, error) {
	tok, ok := streamToken(lane)
	if !ok {
		return "", ErrUnroutableLane
	}
	return fmt.Sprintf("EDGE_%s_V%d", streamName(tok), SubjectVersion), nil
}

// PhysicalDLQStream returns the physical DLQ-stream name for a lane, distinct
// from the data stream.
func PhysicalDLQStream(lane edgev1.EdgeResultLaneKind) (string, error) {
	tok, ok := streamToken(lane)
	if !ok {
		return "", ErrUnroutableLane
	}
	return fmt.Sprintf("EDGE_DLQ_%s_V%d", streamName(tok), SubjectVersion), nil
}

// RoutableLanes lists every lane kind with a defined route, in a stable order.
func RoutableLanes() []edgev1.EdgeResultLaneKind {
	return []edgev1.EdgeResultLaneKind{
		edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_BULK,
		edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_INTERACTIVE,
		edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_MTR_BULK,
		edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_MTR_INTERACTIVE,
		edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_RECOVERY_CONTROL,
	}
}

// streamName upper-cases a subject token into a stream-name fragment
// ("sweep.bulk" -> "SWEEP_BULK").
func streamName(tok string) string {
	out := make([]byte, 0, len(tok))
	for i := 0; i < len(tok); i++ {
		c := tok[i]
		switch {
		case c == '.':
			out = append(out, '_')
		case c >= 'a' && c <= 'z':
			out = append(out, c-('a'-'A'))
		default:
			out = append(out, c)
		}
	}
	return string(out)
}
