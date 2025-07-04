package core

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

func TestDeviceRegistry_EnrichSweepResultWithAlternateIPs(t *testing.T) {
	ctx := context.Background()
	
	// Create mock controller and database
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()
	
	mockDB := db.NewMockService(ctrl)
	
	// Create device registry with mock
	registry := NewDeviceRegistry(mockDB)

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
	err := registry.enrichSweepResultWithAlternateIPs(ctx, sweepResult)
	
	// Verify results
	assert.NoError(t, err)
	
	// Check that alternate IPs were added
	alternateIPs := extractAlternateIPs(sweepResult.Metadata)
	expected := []string{"192.168.1.1", "10.0.0.1", "172.16.0.1"}
	assert.ElementsMatch(t, expected, alternateIPs)
}

func TestDeviceRegistry_ProcessBatchSweepResults_WithEnrichment(t *testing.T) {
	ctx := context.Background()
	
	// Create mock controller and database
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()
	
	mockDB := db.NewMockService(ctrl)
	
	// Create device registry with mock
	registry := NewDeviceRegistry(mockDB)

	// Test data: existing device with alternate IPs
	existingDevice := &models.UnifiedDevice{
		DeviceID: "default:192.168.1.1",
		IP:       "192.168.1.1",
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"alternate_ips": `["10.0.0.1"]`,
			},
		},
	}

	// Input sweep results
	inputResults := []*models.SweepResult{
		{
			IP:       "192.168.1.100",
			Metadata: map[string]string{},
		},
	}

	// Setup mock expectations for enrichment query
	mockDB.EXPECT().GetUnifiedDevicesByIPsOrIDs(ctx, []string{"192.168.1.100"}, []string(nil)).
		Return([]*models.UnifiedDevice{existingDevice}, nil)

	// Setup mock expectation for the final publish call
	// We need to match the enriched results
	mockDB.EXPECT().PublishBatchSweepResults(ctx, gomock.Any()).
		Do(func(ctx context.Context, results []*models.SweepResult) {
			// Verify that the results were enriched
			assert.Len(t, results, 1)
			assert.Equal(t, "192.168.1.100", results[0].IP)
			
			// Check that alternate IPs were added
			alternateIPs := extractAlternateIPs(results[0].Metadata)
			expected := []string{"192.168.1.1", "10.0.0.1"}
			assert.ElementsMatch(t, expected, alternateIPs)
		}).
		Return(nil)

	// Call the method
	err := registry.ProcessBatchSweepResults(ctx, inputResults)
	
	// Verify no error
	assert.NoError(t, err)
}

func TestDeviceRegistry_ProcessBatchSweepResults_NoExistingDevices(t *testing.T) {
	ctx := context.Background()
	
	// Create mock controller and database
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()
	
	mockDB := db.NewMockService(ctrl)
	
	// Create device registry with mock
	registry := NewDeviceRegistry(mockDB)

	// Input sweep results
	inputResults := []*models.SweepResult{
		{
			IP:       "192.168.1.100",
			Metadata: map[string]string{},
		},
	}

	// Setup mock expectations - no existing devices
	mockDB.EXPECT().GetUnifiedDevicesByIPsOrIDs(ctx, []string{"192.168.1.100"}, []string(nil)).
		Return([]*models.UnifiedDevice{}, nil)

	// Setup mock expectation for the final publish call
	mockDB.EXPECT().PublishBatchSweepResults(ctx, inputResults).Return(nil)

	// Call the method
	err := registry.ProcessBatchSweepResults(ctx, inputResults)
	
	// Verify no error
	assert.NoError(t, err)
}