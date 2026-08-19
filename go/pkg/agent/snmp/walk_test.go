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

// Package snmp pkg/agent/snmp/walk_test.go
package snmp

import (
	"context"
	"testing"
	"time"

	"github.com/gosnmp/gosnmp"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// CLEARPASS-MIB service table columns - a real table that can only be collected
// by walking, because its row indices shift as services come and go.
const (
	cppmServiceNameColumn  = ".1.3.6.1.4.1.14823.1.6.1.1.3.1.1.2"
	cppmServiceCountColumn = ".1.3.6.1.4.1.14823.1.6.1.1.3.1.1.4"

	testDataChanBuffer = 32
)

func TestWalkIndex(t *testing.T) {
	tests := []struct {
		name    string
		rootOID string
		oid     string
		want    string
	}{
		{
			name:    "single digit row index",
			rootOID: cppmServiceNameColumn,
			oid:     cppmServiceNameColumn + ".3",
			want:    "3",
		},
		{
			name:    "composite row index",
			rootOID: ".1.3.6.1.2.1.4.22.1.2",
			oid:     ".1.3.6.1.2.1.4.22.1.2.7.10.0.0.1",
			want:    "7.10.0.0.1",
		},
		{
			name:    "root without leading dot still matches",
			rootOID: "1.3.6.1.4.1.14823.1.6.1.1.3.1.1.2",
			oid:     cppmServiceNameColumn + ".11",
			want:    "11",
		},
		{
			name:    "walked root is itself a leaf",
			rootOID: ".1.3.6.1.2.1.1.5.0",
			oid:     ".1.3.6.1.2.1.1.5.0",
			want:    "",
		},
		{
			name:    "sibling column that merely shares a digit prefix is not a row",
			rootOID: ".1.3.6.1.2.1.2.2.1.1",
			oid:     ".1.3.6.1.2.1.2.2.1.10.3",
			want:    "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.Equal(t, tt.want, walkIndex(tt.rootOID, tt.oid))
		})
	}
}

func TestUsesBulkWalk(t *testing.T) {
	tests := []struct {
		name    string
		version gosnmp.SnmpVersion
		want    bool
	}{
		{name: "v1 has no GETBULK PDU", version: gosnmp.Version1, want: false},
		{name: "v2c uses GETBULK", version: gosnmp.Version2c, want: true},
		{name: "v3 uses GETBULK", version: gosnmp.Version3, want: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.Equal(t, tt.want, usesBulkWalk(tt.version))
		})
	}
}

func TestWalkPointName(t *testing.T) {
	tests := []struct {
		name     string
		oidName  string
		rowIndex string
		wantName string
	}{
		{
			name:     "row index becomes part of the series name",
			oidName:  "cppmServiceName",
			rowIndex: "3",
			wantName: "cppmServiceName::index:3",
		},
		{
			name:     "leaf row keeps the configured name",
			oidName:  "sysName",
			rowIndex: "",
			wantName: "sysName",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.Equal(t, tt.wantName, walkPointName(tt.oidName, tt.rowIndex))
		})
	}
}

func TestWalkCollector_Visit(t *testing.T) {
	tests := []struct {
		name        string
		maxRows     int
		variables   []gosnmp.SnmpPDU
		wantResults []WalkResult
		wantErr     error
	}{
		{
			name:    "collects one result per row with its index",
			maxRows: defaultWalkMaxRows,
			variables: []gosnmp.SnmpPDU{
				{Name: cppmServiceNameColumn + ".1", Type: gosnmp.OctetString, Value: []byte("radius")},
				{Name: cppmServiceNameColumn + ".2", Type: gosnmp.OctetString, Value: []byte("tacacs")},
			},
			wantResults: []WalkResult{
				{OID: cppmServiceNameColumn + ".1", Index: "1", Value: "radius"},
				{OID: cppmServiceNameColumn + ".2", Index: "2", Value: "tacacs"},
			},
		},
		{
			name:    "skips unsupported instances but keeps the rest of the table",
			maxRows: defaultWalkMaxRows,
			variables: []gosnmp.SnmpPDU{
				{Name: cppmServiceCountColumn + ".1", Type: gosnmp.Counter64, Value: uint64(42)},
				{Name: cppmServiceCountColumn + ".2", Type: gosnmp.NoSuchInstance, Value: nil},
				{Name: cppmServiceCountColumn + ".3", Type: gosnmp.Counter64, Value: uint64(7)},
			},
			wantResults: []WalkResult{
				{OID: cppmServiceCountColumn + ".1", Index: "1", Value: CounterValue{Value: 42, Width: 64}},
				{OID: cppmServiceCountColumn + ".3", Index: "3", Value: CounterValue{Value: 7, Width: 64}},
			},
		},
		{
			name:    "stops at the row limit and keeps the rows collected so far",
			maxRows: 2,
			variables: []gosnmp.SnmpPDU{
				{Name: cppmServiceNameColumn + ".1", Type: gosnmp.OctetString, Value: []byte("radius")},
				{Name: cppmServiceNameColumn + ".2", Type: gosnmp.OctetString, Value: []byte("tacacs")},
				{Name: cppmServiceNameColumn + ".3", Type: gosnmp.OctetString, Value: []byte("https")},
			},
			wantResults: []WalkResult{
				{OID: cppmServiceNameColumn + ".1", Index: "1", Value: "radius"},
				{OID: cppmServiceNameColumn + ".2", Index: "2", Value: "tacacs"},
			},
			wantErr: ErrSNMPWalkRowLimit,
		},
		{
			name:    "fatal conversion errors stop the walk",
			maxRows: defaultWalkMaxRows,
			variables: []gosnmp.SnmpPDU{
				{Name: cppmServiceNameColumn + ".1", Type: gosnmp.OctetString, Value: byte('x')},
			},
			wantResults: []WalkResult{},
			wantErr:     ErrSNMPConvert,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			collector := newWalkCollector(&SNMPClientImpl{}, cppmServiceNameColumn, tt.maxRows, defaultWalkTimeout)
			collector.rootOID = walkRootFor(tt.variables)

			var err error

			for _, variable := range tt.variables {
				if err = collector.visit(variable); err != nil {
					break
				}
			}

			if tt.wantErr != nil {
				require.ErrorIs(t, err, tt.wantErr)
			} else {
				require.NoError(t, err)
			}

			require.Equal(t, tt.wantResults, collector.results)
		})
	}
}

func TestWalkCollector_VisitStopsAtTimeout(t *testing.T) {
	collector := newWalkCollector(&SNMPClientImpl{}, cppmServiceNameColumn, defaultWalkMaxRows, defaultWalkTimeout)
	collector.deadline = time.Now().Add(-time.Second)

	err := collector.visit(gosnmp.SnmpPDU{
		Name:  cppmServiceNameColumn + ".1",
		Type:  gosnmp.OctetString,
		Value: []byte("radius"),
	})

	require.ErrorIs(t, err, ErrSNMPWalkTimeout)
	require.True(t, isWalkBoundError(err))
	require.Empty(t, collector.results)
}

func TestCollectorPollTarget_Modes(t *testing.T) {
	tests := []struct {
		name           string
		oids           []OIDConfig
		setupMock      func(*MockSNMPClient)
		wantErr        error
		wantAvailable  bool
		wantPoints     map[string]interface{}
		wantPointIndex map[string]string
	}{
		{
			name: "get only target still issues a single get and no walk",
			oids: []OIDConfig{
				{OID: ".1.3.6.1.2.1.1.5.0", Name: "sysName", DataType: TypeString, Scale: 1},
			},
			setupMock: func(client *MockSNMPClient) {
				client.EXPECT().
					Get([]string{".1.3.6.1.2.1.1.5.0"}).
					Return(map[string]interface{}{".1.3.6.1.2.1.1.5.0": "cppm-1"}, nil)
			},
			wantAvailable:  true,
			wantPoints:     map[string]interface{}{"sysName": "cppm-1"},
			wantPointIndex: map[string]string{"sysName": ""},
		},
		{
			name: "walk emits one point per row tagged with its index",
			oids: []OIDConfig{
				{OID: cppmServiceNameColumn, Name: "cppmServiceName", DataType: TypeString, Scale: 1, Mode: ModeWalk},
			},
			setupMock: func(client *MockSNMPClient) {
				client.EXPECT().
					Walk(cppmServiceNameColumn, defaultWalkMaxRows, defaultWalkTimeout).
					Return([]WalkResult{
						{OID: cppmServiceNameColumn + ".1", Index: "1", Value: "radius"},
						{OID: cppmServiceNameColumn + ".2", Index: "2", Value: "tacacs"},
					}, nil)
			},
			wantAvailable: true,
			wantPoints: map[string]interface{}{
				"cppmServiceName::index:1": "radius",
				"cppmServiceName::index:2": "tacacs",
			},
			wantPointIndex: map[string]string{
				"cppmServiceName::index:1": "1",
				"cppmServiceName::index:2": "2",
			},
		},
		{
			name: "configured walk bounds are passed through to the client",
			oids: []OIDConfig{
				{
					OID:         cppmServiceCountColumn,
					Name:        "cppmServiceCount",
					DataType:    TypeCounter,
					Scale:       1,
					Mode:        ModeWalk,
					MaxRows:     10,
					WalkTimeout: Duration(2 * time.Second),
				},
			},
			setupMock: func(client *MockSNMPClient) {
				client.EXPECT().
					Walk(cppmServiceCountColumn, 10, 2*time.Second).
					Return([]WalkResult{
						{OID: cppmServiceCountColumn + ".1", Index: "1", Value: CounterValue{Value: 42, Width: 64}},
					}, nil)
			},
			wantAvailable:  true,
			wantPoints:     map[string]interface{}{"cppmServiceCount::index:1": uint64(42)},
			wantPointIndex: map[string]string{"cppmServiceCount::index:1": "1"},
		},
		{
			name: "get and walk OIDs are collected in the same poll",
			oids: []OIDConfig{
				{OID: ".1.3.6.1.2.1.1.5.0", Name: "sysName", DataType: TypeString, Scale: 1},
				{OID: cppmServiceNameColumn, Name: "cppmServiceName", DataType: TypeString, Scale: 1, Mode: ModeWalk},
			},
			setupMock: func(client *MockSNMPClient) {
				client.EXPECT().
					Get([]string{".1.3.6.1.2.1.1.5.0"}).
					Return(map[string]interface{}{".1.3.6.1.2.1.1.5.0": "cppm-1"}, nil)
				client.EXPECT().
					Walk(cppmServiceNameColumn, defaultWalkMaxRows, defaultWalkTimeout).
					Return([]WalkResult{
						{OID: cppmServiceNameColumn + ".1", Index: "1", Value: "radius"},
					}, nil)
			},
			wantAvailable: true,
			wantPoints: map[string]interface{}{
				"sysName":                  "cppm-1",
				"cppmServiceName::index:1": "radius",
			},
			wantPointIndex: map[string]string{
				"sysName":                  "",
				"cppmServiceName::index:1": "1",
			},
		},
		{
			name: "a bounded walk keeps the partial table it collected",
			oids: []OIDConfig{
				{OID: cppmServiceNameColumn, Name: "cppmServiceName", DataType: TypeString, Scale: 1, Mode: ModeWalk, MaxRows: 1},
			},
			setupMock: func(client *MockSNMPClient) {
				client.EXPECT().
					Walk(cppmServiceNameColumn, 1, defaultWalkTimeout).
					Return([]WalkResult{
						{OID: cppmServiceNameColumn + ".1", Index: "1", Value: "radius"},
					}, ErrSNMPWalkRowLimit)
			},
			wantAvailable:  true,
			wantPoints:     map[string]interface{}{"cppmServiceName::index:1": "radius"},
			wantPointIndex: map[string]string{"cppmServiceName::index:1": "1"},
		},
		{
			name: "a failed walk marks the target unavailable",
			oids: []OIDConfig{
				{OID: cppmServiceNameColumn, Name: "cppmServiceName", DataType: TypeString, Scale: 1, Mode: ModeWalk},
			},
			setupMock: func(client *MockSNMPClient) {
				client.EXPECT().
					Walk(cppmServiceNameColumn, defaultWalkMaxRows, defaultWalkTimeout).
					Return(nil, ErrSNMPConnect)
			},
			wantErr:        ErrSNMPWalk,
			wantAvailable:  false,
			wantPoints:     map[string]interface{}{},
			wantPointIndex: map[string]string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			client := NewMockSNMPClient(ctrl)
			tt.setupMock(client)

			collector := newTestCollector(client, tt.oids)

			err := collector.pollTarget(context.Background())
			if tt.wantErr != nil {
				require.ErrorIs(t, err, tt.wantErr)
			} else {
				require.NoError(t, err)
			}

			require.Equal(t, tt.wantAvailable, collector.GetStatus().Available)

			points := drainDataPoints(collector)
			values := make(map[string]interface{}, len(points))
			indexes := make(map[string]string, len(points))

			for _, point := range points {
				values[point.OIDName] = point.Value
				indexes[point.OIDName] = point.OIDIndex
			}

			require.Equal(t, tt.wantPoints, values)
			require.Equal(t, tt.wantPointIndex, indexes)
		})
	}
}

// Rows of the same walked column keep independent delta state, so one row's rate
// is never computed against a different row's previous sample.
func TestCollectorPollTarget_WalkRowsKeepIndependentDeltaState(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	oidConfig := OIDConfig{
		OID:      cppmServiceCountColumn,
		Name:     "cppmServiceCount",
		DataType: TypeGauge,
		Scale:    1,
		Delta:    true,
		Mode:     ModeWalk,
	}

	collector := newTestCollector(nil, []OIDConfig{oidConfig})
	collector.status.OIDStatus["cppmServiceCount::index:1"] = OIDStatus{
		LastValue:  uint64(100),
		LastUpdate: time.Now().Add(-10 * time.Second),
	}

	rows := []WalkResult{
		{OID: cppmServiceCountColumn + ".1", Index: "1", Value: uint64(200)},
		{OID: cppmServiceCountColumn + ".2", Index: "2", Value: uint64(9000)},
	}

	for i := range rows {
		require.NoError(t, collector.processWalkResult(context.Background(), &oidConfig, &rows[i]))
	}

	points := drainDataPoints(collector)
	require.Len(t, points, 1, "row 2 has no previous sample yet, so only row 1 emits a rate")
	require.Equal(t, "cppmServiceCount::index:1", points[0].OIDName)
	require.Equal(t, "1", points[0].OIDIndex)
	require.InDelta(t, 10.0, points[0].Value, 0.1)
}

func TestDataChanBuffer(t *testing.T) {
	tests := []struct {
		name string
		oids []OIDConfig
		want int
	}{
		{
			name: "get only target keeps its previous buffer size",
			oids: []OIDConfig{
				{OID: ".1.3.6.1.2.1.1.5.0", Name: "sysName"},
				{OID: ".1.3.6.1.2.1.1.3.0", Name: "sysUpTime"},
			},
			want: 2 * defaultDataChanBufferMultiplier,
		},
		{
			name: "a walked OID is budgeted for its rows",
			oids: []OIDConfig{
				{OID: ".1.3.6.1.2.1.1.5.0", Name: "sysName"},
				{OID: cppmServiceNameColumn, Name: "cppmServiceName", Mode: ModeWalk},
			},
			want: defaultDataChanBufferMultiplier + defaultWalkChanBufferRows,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.Equal(t, tt.want, dataChanBuffer(&Target{OIDs: tt.oids}))
		})
	}
}

func TestValidateOIDConfig_WalkMode(t *testing.T) {
	tests := []struct {
		name            string
		oid             OIDConfig
		wantErr         error
		wantMode        OIDMode
		wantRowLimit    int
		wantWalkTimeout time.Duration
	}{
		{
			name:            "missing mode keeps the historical get behavior",
			oid:             OIDConfig{OID: ".1.3.6.1.2.1.1.5.0", Name: "sysName", DataType: TypeString},
			wantMode:        "",
			wantRowLimit:    defaultWalkMaxRows,
			wantWalkTimeout: defaultWalkTimeout,
		},
		{
			name: "walk mode without bounds falls back to the defaults",
			oid: OIDConfig{
				OID: cppmServiceNameColumn, Name: "cppmServiceName", DataType: TypeString, Mode: ModeWalk,
			},
			wantMode:        ModeWalk,
			wantRowLimit:    defaultWalkMaxRows,
			wantWalkTimeout: defaultWalkTimeout,
		},
		{
			name: "walk mode honors explicit bounds",
			oid: OIDConfig{
				OID:         cppmServiceNameColumn,
				Name:        "cppmServiceName",
				DataType:    TypeString,
				Mode:        ModeWalk,
				MaxRows:     25,
				WalkTimeout: Duration(3 * time.Second),
			},
			wantMode:        ModeWalk,
			wantRowLimit:    25,
			wantWalkTimeout: 3 * time.Second,
		},
		{
			name: "unknown mode is rejected",
			oid: OIDConfig{
				OID: cppmServiceNameColumn, Name: "cppmServiceName", DataType: TypeString, Mode: "bulk",
			},
			wantErr: errInvalidOIDMode,
		},
		{
			name: "negative row limit is rejected",
			oid: OIDConfig{
				OID: cppmServiceNameColumn, Name: "cppmServiceName", DataType: TypeString, Mode: ModeWalk, MaxRows: -1,
			},
			wantErr: errInvalidWalkMaxRows,
		},
		{
			name: "negative walk timeout is rejected",
			oid: OIDConfig{
				OID:         cppmServiceNameColumn,
				Name:        "cppmServiceName",
				DataType:    TypeString,
				Mode:        ModeWalk,
				WalkTimeout: Duration(-time.Second),
			},
			wantErr: errInvalidWalkTimeout,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			oid := tt.oid

			err := validateOIDConfig(&oid, make(map[string]bool))
			if tt.wantErr != nil {
				require.ErrorIs(t, err, tt.wantErr)

				return
			}

			require.NoError(t, err)
			require.Equal(t, tt.wantMode, oid.Mode)
			require.Equal(t, tt.wantRowLimit, oid.walkRowLimit())
			require.Equal(t, tt.wantWalkTimeout, oid.walkTimeout())
			require.InDelta(t, 1.0, oid.Scale, 1e-9)
		})
	}
}

// newTestCollector builds a collector wired to a mock client, matching how the
// existing collector tests construct one without touching the network.
func newTestCollector(client SNMPClient, oids []OIDConfig) *SNMPCollector {
	return &SNMPCollector{
		target: &Target{
			Name: "cppm-1",
			Host: "10.0.0.1",
			OIDs: oids,
		},
		client:   client,
		dataChan: make(chan DataPoint, testDataChanBuffer),
		done:     make(chan struct{}),
		status: TargetStatus{
			OIDStatus: make(map[string]OIDStatus),
		},
		logger: logger.NewTestLogger(),
	}
}

func drainDataPoints(collector *SNMPCollector) []DataPoint {
	points := make([]DataPoint, 0, len(collector.dataChan))

	for {
		select {
		case point := <-collector.dataChan:
			points = append(points, point)
		default:
			return points
		}
	}
}

// walkRootFor returns the column OID the test variables belong to, so a collector
// built for one column can be reused for another.
func walkRootFor(variables []gosnmp.SnmpPDU) string {
	if len(variables) == 0 {
		return cppmServiceNameColumn
	}

	if walkIndex(cppmServiceCountColumn, variables[0].Name) != "" {
		return cppmServiceCountColumn
	}

	return cppmServiceNameColumn
}
