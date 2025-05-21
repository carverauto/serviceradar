package metricstore

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/carverauto/serviceradar/pkg/models"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
)

type snmpManagerImpl struct { // Renamed from SNMPMetricsManager
	db db.Service
}

// NewSNMPManager creates a new SNMPManager instance.
func NewSNMPManager(d db.Service) SNMPManager { // Returns interface
	return &snmpManagerImpl{
		db: d,
	}
}

// GetSNMPMetrics fetches SNMP metrics from the database for a given poller.
func (s *snmpManagerImpl) GetSNMPMetrics(ctx context.Context, pollerID string, startTime, endTime time.Time) ([]models.SNMPMetric, error) {
	log.Printf("Fetching SNMP metrics for poller %s from %v to %v", pollerID, startTime, endTime)

	// This call will now use the metrics.TimeseriesMetric from the new package
	tsMetrics, err := s.db.GetMetricsByType(ctx, pollerID, "snmp", startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query SNMP metrics: %w", err)
	}

	snmpMetrics := make([]models.SNMPMetric, 0, len(tsMetrics)) // Use metrics.SNMPMetric

	for _, m := range tsMetrics { // Loop through metrics.TimeseriesMetric
		snmpMetric := models.SNMPMetric{ // Create metrics.SNMPMetric
			OIDName:   m.Name,
			Value:     m.Value,
			ValueType: m.Type,
			Timestamp: m.Timestamp,
			Scale:     1.0, // Default value
			IsDelta:   false,
		}

		// Extract scale and is_delta from metadata
		if m.Metadata != nil {
			var metadata map[string]interface{}

			// Handle different possible types of m.Metadata
			switch md := m.Metadata.(type) {
			case []byte:
				// If it's already []byte, use it directly
				if err := json.Unmarshal(md, &metadata); err != nil {
					log.Printf("Failed to unmarshal metadata for metric %s on poller %s: %v", m.Name, pollerID, err)
					continue
				}
			case string:
				// If it's a string, convert to []byte
				if err := json.Unmarshal([]byte(md), &metadata); err != nil {
					log.Printf("Failed to unmarshal metadata for metric %s on poller %s: %v", m.Name, pollerID, err)
					continue
				}
			case map[string]interface{}:
				// If it's already a map, use it directly
				metadata = md
			default:
				// For other types, try to marshal and then unmarshal
				metadataBytes, err := json.Marshal(m.Metadata)
				if err != nil {
					log.Printf("Failed to marshal metadata for metric %s on poller %s: %v", m.Name, pollerID, err)
					continue
				}
				if err := json.Unmarshal(metadataBytes, &metadata); err != nil {
					log.Printf("Failed to unmarshal metadata for metric %s on poller %s: %v", m.Name, pollerID, err)
					continue
				}
			}

			if scale, ok := metadata["scale"].(float64); ok {
				snmpMetric.Scale = scale
			}
			if isDelta, ok := metadata["is_delta"].(bool); ok {
				snmpMetric.IsDelta = isDelta
			}
		}
		snmpMetrics = append(snmpMetrics, snmpMetric)
	}
	return snmpMetrics, nil
}
