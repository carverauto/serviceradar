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

package addon

import (
	"math"

	"github.com/carverauto/serviceradar/proto"
)

// ToProtoStatuses maps add-on manager snapshots into monitoring SidecarStatus
// entries for the agent capability advertisement. Add-on names are prefixed with
// "addon:" to distinguish supervised add-ons from native sidecars in the shared
// status list, and a non-healthy add-on's degradation reason is surfaced through
// LastError when no other error is present.
func ToProtoStatuses(statuses []Status) []*proto.SidecarStatus {
	if len(statuses) == 0 {
		return nil
	}

	out := make([]*proto.SidecarStatus, 0, len(statuses))
	for _, status := range statuses {
		lastHealthAt := int64(0)
		if !status.LastHealthAt.IsZero() {
			lastHealthAt = status.LastHealthAt.UTC().UnixNano()
		}

		lastError := status.LastError
		if lastError == "" {
			lastError = status.DegradationReason
		}
		if lastError == "" {
			lastError = status.ResourceLimitErr
		}

		out = append(out, &proto.SidecarStatus{
			Name:         "addon:" + status.ID,
			State:        string(status.State),
			Pid:          int32(status.PID),
			LastHealthAt: lastHealthAt,
			RestartCount: cappedUint32(status.RestartCount),
			LastError:    lastError,
			Version:      status.Version,
			Arch:         status.Arch,
		})
	}

	return out
}

func cappedUint32(value int) uint32 {
	if value <= 0 {
		return 0
	}
	if value > math.MaxUint32 {
		return math.MaxUint32
	}

	return uint32(value)
}
