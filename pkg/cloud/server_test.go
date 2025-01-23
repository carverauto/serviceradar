package cloud

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/cloud/api"
	"github.com/mfreeman451/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestProcessSweepData(t *testing.T) {
	server := &Server{}
	now := time.Now()

	tests := []struct {
		name          string
		inputMessage  string
		expectedSweep proto.SweepServiceStatus
		expectError   bool
	}{
		{
			name:         "Valid timestamp",
			inputMessage: `{"network": "192.168.1.0/24", "total_hosts": 10, "available_hosts": 5, "last_sweep": 1678886400}`, // Example timestamp
			expectedSweep: proto.SweepServiceStatus{
				Network:        "192.168.1.0/24",
				TotalHosts:     10,
				AvailableHosts: 5,
				LastSweep:      1678886400,
			},
			expectError: false,
		},
		{
			name:         "Invalid timestamp (far future)",
			inputMessage: `{"network": "192.168.1.0/24", "total_hosts": 10, "available_hosts": 5, "last_sweep": 4102444800}`, // 2100-01-01
			expectedSweep: proto.SweepServiceStatus{
				Network:        "192.168.1.0/24",
				TotalHosts:     10,
				AvailableHosts: 5,
				LastSweep:      now.Unix(),
			},
			expectError: false,
		},
		{
			name:         "Invalid JSON",
			inputMessage: `{"network": "192.168.1.0/24", "total_hosts": "invalid", "available_hosts": 5, "last_sweep": 1678886400}`,
			expectError:  true,
		},
	}

	for i := range tests {
		tt := &tests[i] // Correctly get a pointer to the test case
		t.Run(tt.name, func(t *testing.T) {
			svc := &api.ServiceStatus{
				Message: tt.inputMessage,
			}

			err := server.processSweepData(svc, now)

			if tt.expectError {
				assert.Error(t, err)
			} else {
				require.NoError(t, err)

				var sweepData proto.SweepServiceStatus
				err = json.Unmarshal([]byte(svc.Message), &sweepData)
				require.NoError(t, err)

				assert.Equal(t, tt.expectedSweep.Network, sweepData.Network)
				assert.Equal(t, tt.expectedSweep.TotalHosts, sweepData.TotalHosts)
				assert.Equal(t, tt.expectedSweep.AvailableHosts, sweepData.AvailableHosts)

				// For timestamps, compare with a small delta to account for processing time
				if tt.expectedSweep.LastSweep == now.Unix() {
					assert.InDelta(t, tt.expectedSweep.LastSweep, sweepData.LastSweep, 5) // Allow 5 seconds difference
				} else {
					assert.Equal(t, tt.expectedSweep.LastSweep, sweepData.LastSweep)
				}
			}
		})
	}
}
