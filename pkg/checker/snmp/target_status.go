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

// Package snmp pkg/checker/snmp/target_status.go
package snmp

const (
	defaultUnknown = "unknown"
)

// GetDataType returns the data type for the given OID.
func (ts *TargetStatus) GetDataType(oidName string) string {
	if ts.Target == nil {
		return defaultUnknown
	}

	for _, oid := range ts.Target.OIDs {
		if oid.Name == oidName {
			return string(oid.DataType)
		}
	}

	return defaultUnknown
}

// GetScale returns the scale factor for the given OID.
func (ts *TargetStatus) GetScale(oidName string) float64 {
	if ts.Target == nil {
		return 1.0
	}

	for _, oid := range ts.Target.OIDs {
		if oid.Name == oidName {
			return oid.Scale
		}
	}

	return 1.0
}

// GetDelta returns whether the OID is configured as a delta value.
func (ts *TargetStatus) GetDelta(oidName string) bool {
	if ts.Target == nil {
		return false
	}

	for _, oid := range ts.Target.OIDs {
		if oid.Name == oidName {
			return oid.Delta
		}
	}

	return false
}

// SetTarget sets the target configuration.
func (ts *TargetStatus) SetTarget(target *Target) {
	ts.Target = target
}
