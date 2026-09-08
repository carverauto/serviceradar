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

	results := (&PushLoop{}).buildSNMPDrainedResults(statuses, metrics, "")
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

func TestBuildSNMPDrainedResultsTagsWalkedIfTableRows(t *testing.T) {
	statuses := map[string]snmpchecker.TargetStatus{
		"udm": {
			HostIP: "192.168.2.254",
			Target: &snmpchecker.Target{
				OIDs: []snmpchecker.OIDConfig{
					{
						OID:      ".1.3.6.1.2.1.31.1.1.1.6",
						Name:     "ifInOctets",
						DataType: snmpchecker.TypeCounter,
						Scale:    1,
						Delta:    true,
						Mode:     snmpchecker.ModeWalk,
					},
					{
						OID:      ".1.3.6.1.2.1.31.1.1.1.6.13",
						Name:     "ifInOctets::ifindex:13",
						DataType: snmpchecker.TypeCounter,
						Scale:    1,
						Delta:    true,
					},
				},
			},
		},
	}

	observedAt := time.Date(2026, 8, 20, 6, 57, 0, 0, time.UTC)
	metrics := map[string][]snmpchecker.DataPoint{
		"udm|ifInOctets::index:13": {
			{
				OIDName:      "ifInOctets::index:13",
				OIDIndex:     "13",
				Value:        uint64(100),
				RawValue:     uint64(100),
				Timestamp:    observedAt,
				DataType:     snmpchecker.TypeCounter,
				Kind:         "sum",
				Temporality:  "cumulative",
				IsMonotonic:  true,
				CounterWidth: 64,
			},
		},
		"udm|ifInOctets::index:520": {
			{
				OIDName:      "ifInOctets::index:520",
				OIDIndex:     "520",
				Value:        uint64(200),
				RawValue:     uint64(200),
				Timestamp:    observedAt,
				DataType:     snmpchecker.TypeCounter,
				Kind:         "sum",
				Temporality:  "cumulative",
				IsMonotonic:  true,
				CounterWidth: 64,
			},
		},
	}

	results := (&PushLoop{}).buildSNMPDrainedResults(statuses, metrics, "")
	require.Len(t, results, 2)

	byIndex := map[int]snmpMetricResult{}
	for _, result := range results {
		require.NotNil(t, result.IfIndex, "walked IF-MIB rows must carry ifIndex, got %+v", result)
		byIndex[*result.IfIndex] = result
	}

	row13 := byIndex[13]
	require.Equal(t, "ifInOctets", row13.Metric)
	require.Equal(t, "ifindex:13", row13.InterfaceUID)
	require.Equal(t, ".1.3.6.1.2.1.31.1.1.1.6.13", row13.OID)

	row520 := byIndex[520]
	require.Equal(t, "ifInOctets", row520.Metric)
	require.Equal(t, "ifindex:520", row520.InterfaceUID)
	require.Equal(t, ".1.3.6.1.2.1.31.1.1.1.6.520", row520.OID)
}

func TestBuildSNMPDrainedResultsDoesNotTreatNonIfTableWalkIndexAsIfIndex(t *testing.T) {
	statuses := map[string]snmpchecker.TargetStatus{
		"clearpass": {
			HostIP: "10.0.0.8",
			Target: &snmpchecker.Target{
				OIDs: []snmpchecker.OIDConfig{
					{
						OID:      ".1.3.6.1.4.1.14823.1.6.1.1.3.1.1.4",
						Name:     "cppmServiceCount",
						DataType: snmpchecker.TypeGauge,
						Scale:    1,
						Mode:     snmpchecker.ModeWalk,
					},
				},
			},
		},
	}

	metrics := map[string][]snmpchecker.DataPoint{
		"clearpass|cppmServiceCount::index:3": {
			{
				OIDName:   "cppmServiceCount::index:3",
				OIDIndex:  "3",
				Value:     uint64(12),
				Timestamp: time.Date(2026, 8, 20, 6, 57, 0, 0, time.UTC),
				DataType:  snmpchecker.TypeGauge,
			},
		},
	}

	results := (&PushLoop{}).buildSNMPDrainedResults(statuses, metrics, "")
	require.Len(t, results, 1)
	require.Equal(t, "cppmServiceCount", results[0].Metric)
	require.Equal(t, "index:3", results[0].InterfaceUID)
	require.Nil(t, results[0].IfIndex)
}

func TestBuildSNMPDrainedResultsCopiesProfileID(t *testing.T) {
	profileID := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	statuses := map[string]snmpchecker.TargetStatus{
		"clearpass": {
			HostIP: "10.0.0.8",
			Target: &snmpchecker.Target{
				ID: "target-1",
				OIDs: []snmpchecker.OIDConfig{
					{
						OID:      ".1.3.6.1.4.1.14823.1.6.1.1.1.1.1.3.0",
						Name:     "node_version",
						DataType: snmpchecker.TypeString,
					},
				},
			},
		},
	}

	metrics := map[string][]snmpchecker.DataPoint{
		"clearpass|node_version": {
			{
				OIDName:   "node_version",
				Value:     "6.11.15",
				RawValue:  "6.11.15",
				Timestamp: time.Date(2026, 8, 30, 0, 0, 0, 0, time.UTC),
				DataType:  snmpchecker.TypeString,
			},
		},
	}

	results := (&PushLoop{}).buildSNMPDrainedResults(statuses, metrics, profileID)
	require.Len(t, results, 1)
	require.Equal(t, profileID, results[0].ProfileID)
	require.Equal(t, "6.11.15", results[0].Value)
}
