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

package sidecar

import "github.com/carverauto/serviceradar/proto"

// ToProtoStatuses maps manager snapshots into monitoring StatusResponse fields.
func ToProtoStatuses(statuses []Status) []*proto.SidecarStatus {
	if len(statuses) == 0 {
		return nil
	}

	out := make([]*proto.SidecarStatus, 0, len(statuses))
	for _, status := range statuses {
		lastHealthAt := int64(0)
		if !status.LastHealthAt.IsZero() {
			lastHealthAt = status.LastHealthAt.UTC().Unix()
		}

		out = append(out, &proto.SidecarStatus{
			Name:         status.Name,
			State:        string(status.State),
			Pid:          int32(status.PID),
			LastHealthAt: lastHealthAt,
			RestartCount: uint32(status.RestartCount),
			LastError:    status.LastError,
		})
	}

	return out
}
