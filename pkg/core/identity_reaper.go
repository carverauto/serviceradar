package core

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// IdentityReaper expires network sightings (and later low-confidence devices) per policy.
type IdentityReaper struct {
	db       db.Service
	logger   logger.Logger
	interval time.Duration
}

func NewIdentityReaper(database db.Service, log logger.Logger, interval time.Duration) *IdentityReaper {
	return &IdentityReaper{
		db:       database,
		logger:   log,
		interval: interval,
	}
}

func (r *IdentityReaper) Start(ctx context.Context) {
	r.logger.Info().
		Dur("interval", r.interval).
		Msg("Starting identity reconciliation reaper")

	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			r.logger.Info().Msg("Identity reconciliation reaper stopping")
			return
		case <-ticker.C:
			if err := r.reap(ctx); err != nil {
				r.logger.Error().Err(err).Msg("Failed to reap identity sightings")
			}
		}
	}
}

func (r *IdentityReaper) reap(ctx context.Context) error {
	if r.db == nil {
		return nil
	}

	now := time.Now().UTC()
	expired, err := r.db.ExpireNetworkSightings(ctx, now)
	if err != nil {
		return err
	}

	if len(expired) == 0 {
		return nil
	}

	r.logger.Info().
		Int("expired", len(expired)).
		Msg("Expired stale network sightings")

	events := make([]*models.SightingEvent, 0, len(expired))
	for _, s := range expired {
		events = append(events, &models.SightingEvent{
			SightingID: s.SightingID,
			EventType:  "expired",
			Actor:      "system",
			Details: map[string]string{
				"ip":        s.IP,
				"partition": s.Partition,
			},
			CreatedAt: now,
		})
	}

	if err := r.db.InsertSightingEvents(ctx, events); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to record sighting expiry events")
	}

	return nil
}
