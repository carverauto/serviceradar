package metrics

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

func (m *Manager) StoreRperfMetrics(ctx context.Context, pollerID string, metrics *models.RperfMetrics, timestamp time.Time) error {
	for i := range metrics.Results {
		result := &metrics.Results[i] // Access the element by reference
		metricName := fmt.Sprintf("rperf_%s", strings.ToLower(strings.ReplaceAll(result.Target, " ", "_")))

		metadata, err := json.Marshal(map[string]interface{}{
			"target":           result.Target,
			"success":          result.Success,
			"error":            result.Error,
			"bits_per_second":  result.BitsPerSec,
			"bytes_received":   result.BytesReceived,
			"bytes_sent":       result.BytesSent,
			"duration":         result.Duration,
			"jitter_ms":        result.JitterMs,
			"loss_percent":     result.LossPercent,
			"packets_lost":     result.PacketsLost,
			"packets_received": result.PacketsReceived,
			"packets_sent":     result.PacketsSent,
		})
		if err != nil {
			m.logger.Error().Str("metricName", metricName).Str("pollerID", pollerID).
				Err(err).Msg("Failed to marshal rperf metadata")

			continue
		}

		metric := &models.TimeseriesMetric{
			Name:      metricName,
			Value:     fmt.Sprintf("%f", result.BitsPerSec),
			Type:      "rperf",
			Timestamp: timestamp,
			Metadata:  string(metadata), // Convert []byte to string
		}

		if err := m.db.StoreMetric(ctx, pollerID, metric); err != nil {
			m.logger.Error().Str("metricName", metricName).Str("pollerID", pollerID).
				Err(err).Msg("Error storing rperf metric")

			return fmt.Errorf("failed to store rperf metric: %w", err)
		}

		m.logger.Info().Str("metricName", metricName).Str("pollerID", pollerID).
			Float64("bits_per_second", result.BitsPerSec).Msg("Stored rperf metric")
	}

	return nil
}

func (m *Manager) GetRperfMetrics(ctx context.Context, pollerID, target string, start, end time.Time) ([]models.RperfMetric, error) {
	metricName := fmt.Sprintf("rperf_%s", strings.ToLower(strings.ReplaceAll(target, " ", "_")))

	dbMetrics, err := m.db.GetMetrics(ctx, pollerID, metricName, start, end)
	if err != nil {
		return nil, err
	}

	metrics := make([]models.RperfMetric, 0, len(dbMetrics))

	for i := range dbMetrics {
		dm := &dbMetrics[i] // Access the element by reference

		if dm.Metadata == "" {
			m.logger.Warn().Str("metricName", dm.Name).Str("pollerID", pollerID).Msg("Empty metadata for rperf metric")
			continue
		}

		var metaMap map[string]interface{}

		if err := json.Unmarshal([]byte(dm.Metadata), &metaMap); err != nil {
			m.logger.Error().Str("metricName", dm.Name).Str("pollerID", pollerID).Err(err).Msg("Failed to unmarshal metadata for rperf metric")
			continue
		}

		var errorPtr *string

		if errVal, ok := metaMap["error"]; ok {
			if errStr, ok := errVal.(string); ok && errStr != "" {
				errorPtr = &errStr
			}
		}

		metric := models.RperfMetric{
			Target:          metaMap["target"].(string),
			Success:         metaMap["success"].(bool),
			Error:           errorPtr,
			BitsPerSec:      metaMap["bits_per_second"].(float64),
			BytesReceived:   int64(metaMap["bytes_received"].(float64)),
			BytesSent:       int64(metaMap["bytes_sent"].(float64)),
			Duration:        metaMap["duration"].(float64),
			JitterMs:        metaMap["jitter_ms"].(float64),
			LossPercent:     metaMap["loss_percent"].(float64),
			PacketsLost:     int64(metaMap["packets_lost"].(float64)),
			PacketsReceived: int64(metaMap["packets_received"].(float64)),
			PacketsSent:     int64(metaMap["packets_sent"].(float64)),
			Timestamp:       dm.Timestamp,
		}

		metrics = append(metrics, metric)
	}

	return metrics, nil
}
