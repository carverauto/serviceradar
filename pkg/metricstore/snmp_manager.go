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

type snmpManagerImpl struct {
	db db.Service
}

// NewSNMPManager creates a new SNMPManager instance.
func NewSNMPManager(d db.Service) SNMPManager {
	return &snmpManagerImpl{
		db: d,
	}
}

// parseMetadata extracts a map from various metadata formats
func parseMetadata(metadataObj interface{}, metricName, pollerID string) (map[string]interface{}, bool) {
	if metadataObj == nil {
		return nil, false
	}

	var metadata map[string]interface{}

	// Handle different possible types of metadata
	switch md := metadataObj.(type) {
	case []byte:
		// If it's already []byte, use it directly
		if err := json.Unmarshal(md, &metadata); err != nil {
			log.Printf("Failed to unmarshal metadata for metric %s on poller %s: %v", metricName, pollerID, err)
			return nil, false
		}
	case string:
		// If it's a string, convert to []byte
		if err := json.Unmarshal([]byte(md), &metadata); err != nil {
			log.Printf("Failed to unmarshal metadata for metric %s on poller %s: %v", metricName, pollerID, err)
			return nil, false
		}
	case map[string]interface{}:
		// If it's already a map, use it directly
		metadata = md
	default:
		// For other types, try to marshal and then unmarshal
		metadataBytes, err := json.Marshal(metadataObj)
		if err != nil {
			log.Printf("Failed to marshal metadata for metric %s on poller %s: %v", metricName, pollerID, err)
			return nil, false
		}

		if err := json.Unmarshal(metadataBytes, &metadata); err != nil {
			log.Printf("Failed to unmarshal metadata for metric %s on poller %s: %v", metricName, pollerID, err)
			return nil, false
		}
	}

	return metadata, true
}

// GetSNMPMetrics fetches SNMP metrics from the database for a given poller.
func (s *snmpManagerImpl) GetSNMPMetrics(ctx context.Context, pollerID string, startTime, endTime time.Time) ([]models.SNMPMetric, error) {
	log.Printf("Fetching SNMP metrics for poller %s from %v to %v", pollerID, startTime, endTime)

	tsMetrics, err := s.db.GetMetricsByType(ctx, pollerID, "snmp", startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query SNMP metrics: %w", err)
	}

	snmpMetrics := make([]models.SNMPMetric, 0, len(tsMetrics))

	for _, m := range tsMetrics {
		snmpMetric := models.SNMPMetric{
			OIDName:   m.Name,
			Value:     m.Value,
			ValueType: m.Type,
			Timestamp: m.Timestamp,
			Scale:     1.0, // Default value
			IsDelta:   false,
		}

		// Extract scale and is_delta from metadata
		metadata, ok := parseMetadata(m.Metadata, m.Name, pollerID)
		if ok {
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
