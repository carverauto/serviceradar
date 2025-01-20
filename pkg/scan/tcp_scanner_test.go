package scan

import (
	"context"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTCPScanner_Scan(t *testing.T) {
	tests := []struct {
		name    string
		targets []models.Target
		timeout time.Duration
		wantErr bool
	}{
		{
			name: "scan localhost",
			targets: []models.Target{
				{Host: "127.0.0.1", Port: 22, Mode: models.ModeTCP},
			},
			timeout: 1 * time.Second,
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			scanner := NewTCPScanner(tt.timeout, 1)
			results, err := scanner.Scan(context.Background(), tt.targets)

			if tt.wantErr {
				require.Error(t, err)
				return
			}

			require.NoError(t, err)

			var gotResults []models.Result
			for result := range results {
				gotResults = append(gotResults, result)
			}

			// Verify results
			require.Len(t, gotResults, len(tt.targets))

			for i, result := range gotResults {
				assert.Equal(t, tt.targets[i].Host, result.Target.Host)
				assert.Equal(t, tt.targets[i].Port, result.Target.Port)
				assert.NotZero(t, result.RespTime)
			}
		})
	}
}
