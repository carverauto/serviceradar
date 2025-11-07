package core

import (
	"context"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/models"
)

const statsAlertCooldown = 5 * time.Minute

func (s *Server) handleStatsAnomaly(
	ctx context.Context,
	previousSnapshot *models.DeviceStatsSnapshot,
	previousMeta models.DeviceStatsMeta,
	currentSnapshot *models.DeviceStatsSnapshot,
	currentMeta models.DeviceStatsMeta,
) {
	if len(s.webhooks) == 0 {
		return
	}

	delta := currentMeta.SkippedNonCanonical - previousMeta.SkippedNonCanonical
	if delta <= 0 {
		return
	}

	s.statsAlertMu.Lock()
	if (currentMeta.SkippedNonCanonical <= s.lastStatsAlertCount) && time.Since(s.lastStatsAlertTime) < statsAlertCooldown {
		s.statsAlertMu.Unlock()
		return
	}

	s.lastStatsAlertCount = currentMeta.SkippedNonCanonical
	s.lastStatsAlertTime = time.Now()
	s.statsAlertMu.Unlock()

	message := fmt.Sprintf(
		"Stats aggregator filtered %d newly detected non-canonical devices (total filtered: %d).",
		delta,
		currentMeta.SkippedNonCanonical,
	)

	details := map[string]any{
		"raw_records":                 currentMeta.RawRecords,
		"processed_records":           currentMeta.ProcessedRecords,
		"skipped_non_canonical":       currentMeta.SkippedNonCanonical,
		"inferred_canonical_fallback": currentMeta.InferredCanonicalFallback,
		"skipped_service_components":  currentMeta.SkippedServiceComponents,
		"skipped_tombstoned":          currentMeta.SkippedTombstonedRecords,
		"delta_non_canonical":         delta,
	}

	if currentSnapshot != nil {
		details["snapshot_timestamp"] = currentSnapshot.Timestamp.UTC().Format(time.RFC3339)
		details["total_devices"] = currentSnapshot.TotalDevices
		details["available_devices"] = currentSnapshot.AvailableDevices
	}

	if previousSnapshot != nil {
		details["previous_snapshot_timestamp"] = previousSnapshot.Timestamp.UTC().Format(time.RFC3339)
		if previousSnapshot.TotalDevices != 0 {
			details["previous_total_devices"] = previousSnapshot.TotalDevices
		}
	}

	alert := &alerts.WebhookAlert{
		Level:     alerts.Warning,
		Title:     "Non-canonical devices filtered from stats",
		Message:   message,
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		PollerID:  "core",
		Details:   details,
	}

	if err := s.sendAlert(ctx, alert); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to dispatch stats anomaly alert")
	}
}
