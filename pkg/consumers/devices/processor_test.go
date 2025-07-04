package devices

import (
	"context"
	"testing"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"go.uber.org/mock/gomock"
)

func TestExtractAlternateIPs(t *testing.T) {
	tests := []struct {
		name     string
		metadata map[string]string
		expected []string
	}{
		{
			name:     "empty metadata",
			metadata: map[string]string{},
			expected: nil,
		},
		{
			name: "valid JSON array",
			metadata: map[string]string{
				"alternate_ips": `["192.168.1.1", "10.0.0.1"]`,
			},
			expected: []string{"192.168.1.1", "10.0.0.1"},
		},
		{
			name: "legacy comma-separated format",
			metadata: map[string]string{
				"alternate_ips": "192.168.1.1,10.0.0.1",
			},
			expected: []string{"192.168.1.1", "10.0.0.1"},
		},
		{
			name: "empty alternate_ips",
			metadata: map[string]string{
				"alternate_ips": "",
			},
			expected: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractAlternateIPs(tt.metadata)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestAddAlternateIP(t *testing.T) {
	tests := []struct {
		name     string
		metadata map[string]string
		ip       string
		expected string
	}{
		{
			name:     "add to empty metadata",
			metadata: map[string]string{},
			ip:       "192.168.1.1",
			expected: `["192.168.1.1"]`,
		},
		{
			name: "add to existing JSON array",
			metadata: map[string]string{
				"alternate_ips": `["10.0.0.1"]`,
			},
			ip:       "192.168.1.1",
			expected: `["10.0.0.1","192.168.1.1"]`,
		},
		{
			name: "add duplicate IP (should not change)",
			metadata: map[string]string{
				"alternate_ips": `["192.168.1.1"]`,
			},
			ip:       "192.168.1.1",
			expected: `["192.168.1.1"]`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := addAlternateIP(tt.metadata, tt.ip)
			assert.Equal(t, tt.expected, result["alternate_ips"])
		})
	}
}

func TestEnrichSweepResultWithAlternateIPs(t *testing.T) {
	ctx := context.Background()
	
	// Create mock controller and database
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()
	
	mockDB := db.NewMockService(ctrl)
	
	// Create processor with mock
	processor := &Processor{
		db:       mockDB,
		agentID:  "test-agent",
		pollerID: "test-poller",
	}

	// Test data: existing device with alternate IPs
	existingDevice := &models.UnifiedDevice{
		DeviceID: "default:192.168.1.1",
		IP:       "192.168.1.1",
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"alternate_ips": `["10.0.0.1", "172.16.0.1"]`,
			},
		},
	}

	// Setup mock expectations
	mockDB.EXPECT().GetUnifiedDevicesByIPsOrIDs(ctx, []string{"192.168.1.100"}, []string(nil)).
		Return([]*models.UnifiedDevice{existingDevice}, nil)

	// Test sweep result that should be enriched
	sweepResult := &models.SweepResult{
		IP:       "192.168.1.100",
		Metadata: map[string]string{},
	}

	// Call enrichment
	err := processor.enrichSweepResultWithAlternateIPs(ctx, sweepResult)
	
	// Verify results
	assert.NoError(t, err)
	
	// Check that alternate IPs were added
	alternateIPs := extractAlternateIPs(sweepResult.Metadata)
	expected := []string{"192.168.1.1", "10.0.0.1", "172.16.0.1"}
	assert.ElementsMatch(t, expected, alternateIPs)
}

func TestEnrichSweepResultNoExistingDevices(t *testing.T) {
	ctx := context.Background()
	
	// Create mock controller and database
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()
	
	mockDB := db.NewMockService(ctrl)
	
	// Create processor with mock
	processor := &Processor{
		db:       mockDB,
		agentID:  "test-agent",
		pollerID: "test-poller",
	}

	// Setup mock expectations - no existing devices
	mockDB.EXPECT().GetUnifiedDevicesByIPsOrIDs(ctx, []string{"192.168.1.100"}, []string(nil)).
		Return([]*models.UnifiedDevice{}, nil)

	// Test sweep result
	sweepResult := &models.SweepResult{
		IP:       "192.168.1.100",
		Metadata: map[string]string{},
	}

	// Call enrichment
	err := processor.enrichSweepResultWithAlternateIPs(ctx, sweepResult)
	
	// Verify results - should be no changes since no existing devices
	assert.NoError(t, err)
	assert.Empty(t, sweepResult.Metadata)
}