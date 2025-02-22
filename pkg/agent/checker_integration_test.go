//go:build integration
// +build integration

package agent

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestICMPChecker(t *testing.T) {
	tests := []struct {
		name string
		host string
	}{
		{
			name: "localhost",
			host: "127.0.0.1",
		},
		{
			name: "invalid host",
			host: "invalid.host",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			checker := &ICMPChecker{
				Host:  tt.host,
				Count: 1,
			}

			ctx := context.Background()
			available, response := checker.Check(ctx)

			// We can't reliably test the actual ping result as it depends on the
			// network, but we can verify the response format
			assert.NotEmpty(t, response)
			assert.Contains(t, response, tt.host)

			if available {
				assert.Contains(t, response, "response_time")
				assert.Contains(t, response, "packet_loss")
			}

			// Test Close
			err := checker.Close(ctx)
			assert.NoError(t, err)
		})
	}
}
