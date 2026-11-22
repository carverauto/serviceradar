package models

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestDetermineAgentTypeFromCapabilitiesIncludesNetperf(t *testing.T) {
	tests := []struct {
		name         string
		capabilities []string
		wantID       int
		wantName     string
	}{
		{
			name:         "netperf capability",
			capabilities: []string{"netperf"},
			wantID:       OCSFAgentTypePerformanceMonitoring,
			wantName:     AgentTypeNamePerformanceMonitoring,
		},
		{
			name:         "rperf capability",
			capabilities: []string{"rperf"},
			wantID:       OCSFAgentTypePerformanceMonitoring,
			wantName:     AgentTypeNamePerformanceMonitoring,
		},
		{
			name:         "syslog capability",
			capabilities: []string{"syslog"},
			wantID:       OCSFAgentTypeLogManagement,
			wantName:     AgentTypeNameLogManagement,
		},
		{
			name:         "unknown capability",
			capabilities: []string{"custom"},
			wantID:       OCSFAgentTypeUnknown,
			wantName:     AgentTypeNameUnknown,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			gotID, gotName := DetermineAgentTypeFromCapabilities(tc.capabilities)
			assert.Equal(t, tc.wantID, gotID)
			assert.Equal(t, tc.wantName, gotName)
		})
	}
}
