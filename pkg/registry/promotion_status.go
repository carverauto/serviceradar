package registry

import (
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// promotionStatusForSighting evaluates promotion readiness and blockers for a sighting.
func (r *DeviceRegistry) promotionStatusForSighting(now time.Time, s *models.NetworkSighting) *models.SightingPromotionStatus {
	if s == nil {
		return nil
	}

	status := &models.SightingPromotionStatus{}
	cfg := r.identityCfg
	if cfg == nil {
		status.Blockers = []string{"identity reconciliation disabled"}
		return status
	}

	promo := cfg.Promotion
	status.ShadowMode = promo.ShadowMode

	var (
		blockers    []string
		satisfied   []string
		meetsPolicy = true
	)

	// Min persistence gate.
	if minPersistence := time.Duration(promo.MinPersistence); minPersistence > 0 {
		if s.FirstSeen.IsZero() {
			meetsPolicy = false
			blockers = append(blockers, fmt.Sprintf("waiting for %s persistence window (first_seen missing)", formatDurationShort(minPersistence)))
		} else {
			age := now.Sub(s.FirstSeen)
			if age < minPersistence {
				meetsPolicy = false
				remaining := minPersistence - age
				eligibleAt := s.FirstSeen.Add(minPersistence)
				status.NextEligibleAt = &eligibleAt
				blockers = append(blockers, fmt.Sprintf("waiting for persistence window (%s remaining)", formatDurationShort(remaining)))
			} else {
				satisfied = append(satisfied, "persistence window met")
			}
		}
	}

	metadata := s.Metadata
	hasHostname := metadata != nil && strings.TrimSpace(metadata["hostname"]) != ""
	if promo.RequireHostname {
		if !hasHostname {
			meetsPolicy = false
			blockers = append(blockers, "hostname required by promotion policy")
		} else {
			satisfied = append(satisfied, "hostname present")
		}
	}

	hasFingerprint := false
	if s.FingerprintID != nil && strings.TrimSpace(*s.FingerprintID) != "" {
		hasFingerprint = true
	}
	if metadata != nil {
		if strings.TrimSpace(metadata["fingerprint_id"]) != "" || strings.TrimSpace(metadata["fingerprint_hash"]) != "" {
			hasFingerprint = true
		}
	}
	if promo.RequireFingerprint {
		if !hasFingerprint {
			meetsPolicy = false
			blockers = append(blockers, "fingerprint required by promotion policy")
		} else {
			satisfied = append(satisfied, "fingerprint present")
		}
	}

	status.MeetsPolicy = meetsPolicy

	if !cfg.Enabled {
		blockers = append(blockers, "identity reconciliation disabled")
	}
	if cfg.SightingsOnly {
		blockers = append(blockers, "sightings-only mode (auto-promotion off)")
	}
	if !promo.Enabled {
		blockers = append(blockers, "auto-promotion disabled")
	}
	if promo.ShadowMode {
		blockers = append(blockers, "shadow mode enabled (no automatic promotion)")
	}

	status.Eligible = meetsPolicy &&
		cfg.Enabled &&
		!cfg.SightingsOnly &&
		promo.Enabled &&
		!promo.ShadowMode

	status.Blockers = dedupeStrings(blockers)
	if len(status.Blockers) == 0 {
		status.Blockers = nil
	}

	status.Satisfied = satisfied
	if len(status.Satisfied) == 0 {
		status.Satisfied = nil
	}

	// Avoid returning stale timestamps.
	if status.NextEligibleAt != nil && !status.NextEligibleAt.After(now) {
		status.NextEligibleAt = nil
	}

	return status
}

func dedupeStrings(items []string) []string {
	if len(items) == 0 {
		return items
	}
	seen := make(map[string]struct{}, len(items))
	result := make([]string, 0, len(items))
	for _, item := range items {
		if _, ok := seen[item]; ok {
			continue
		}
		seen[item] = struct{}{}
		result = append(result, item)
	}
	return result
}

func formatDurationShort(d time.Duration) string {
	if d <= 0 {
		return "0s"
	}

	if d >= 24*time.Hour {
		days := d / (24 * time.Hour)
		remainder := d % (24 * time.Hour)
		if remainder == 0 {
			return fmt.Sprintf("%dd", days)
		}
		return fmt.Sprintf("%dd%s", days, formatDurationShort(remainder))
	}

	if d >= time.Hour {
		hours := d / time.Hour
		mins := (d % time.Hour) / time.Minute
		if mins == 0 {
			return fmt.Sprintf("%dh", hours)
		}
		return fmt.Sprintf("%dh%dm", hours, mins)
	}

	if d >= time.Minute {
		mins := d / time.Minute
		secs := (d % time.Minute) / time.Second
		if secs == 0 {
			return fmt.Sprintf("%dm", mins)
		}
		return fmt.Sprintf("%dm%ds", mins, secs)
	}

	return fmt.Sprintf("%ds", int(d.Seconds()))
}
