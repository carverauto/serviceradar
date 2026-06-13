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
	"testing"
	"time"

	snmpchecker "github.com/carverauto/serviceradar/go/pkg/agent/snmp"
	"github.com/stretchr/testify/require"
)

func TestBuildSNMPDrainedResultsPreservesCounterSemantics(t *testing.T) {
	statuses := map[string]snmpchecker.TargetStatus{
		"core-switch": {
			HostIP: "10.0.0.20",
			Target: &snmpchecker.Target{
				OIDs: []snmpchecker.OIDConfig{
					{
						OID:      ".1.3.6.1.2.1.31.1.1.1.6.7",
						Name:     "ifHCInOctets::ifindex:7",
						DataType: snmpchecker.TypeCounter,
						Scale:    1,
						Delta:    true,
					},
				},
			},
		},
	}

	observedAt := time.Date(2026, 6, 13, 18, 20, 0, 0, time.UTC)

	metrics := map[string][]snmpchecker.DataPoint{
		"core-switch|ifHCInOctets::ifindex:7": {
			{
				OIDName:      "ifHCInOctets::ifindex:7",
				Value:        uint64(9_007_199_254_740_993),
				RawValue:     uint64(9_007_199_254_740_993),
				Timestamp:    observedAt,
				DataType:     snmpchecker.TypeCounter,
				Scale:        1,
				Delta:        false,
				Kind:         "sum",
				Temporality:  "cumulative",
				IsMonotonic:  true,
				CounterWidth: 64,
			},
		},
	}

	results := (&PushLoop{}).buildSNMPDrainedResults(statuses, metrics)
	require.Len(t, results, 1)

	result := results[0]
	require.Equal(t, "core-switch", result.Target)
	require.Equal(t, "10.0.0.20", result.Host)
	require.Equal(t, "ifHCInOctets", result.Metric)
	require.Equal(t, ".1.3.6.1.2.1.31.1.1.1.6.7", result.OID)
	require.Equal(t, uint64(9_007_199_254_740_993), result.Value)
	require.Equal(t, uint64(9_007_199_254_740_993), result.RawValue)
	require.Equal(t, "counter", result.DataType)
	require.False(t, result.Delta)
	require.Equal(t, "sum", result.Kind)
	require.Equal(t, "cumulative", result.Temporality)
	require.True(t, result.IsMonotonic)
	require.Equal(t, 64, result.CounterWidth)
	require.Equal(t, "ifindex:7", result.InterfaceUID)
	require.NotNil(t, result.IfIndex)
	require.Equal(t, 7, *result.IfIndex)
	require.Equal(t, observedAt, result.Timestamp)
}
