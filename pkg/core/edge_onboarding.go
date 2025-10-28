package core

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"sync"

	"github.com/carverauto/serviceradar/pkg/crypto/secrets"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var onboardingAllowedStatuses = []models.EdgeOnboardingStatus{
	models.EdgeOnboardingStatusIssued,
	models.EdgeOnboardingStatusDelivered,
	models.EdgeOnboardingStatusActivated,
}

type edgeOnboardingService struct {
	cfg     *models.EdgeOnboardingConfig
	db      db.Service
	logger  logger.Logger
	cipher  *secrets.Cipher
	mu      sync.RWMutex
	allowed map[string]struct{}
}

var errEdgeOnboardingDisabled = errors.New("edge onboarding disabled")

func newEdgeOnboardingService(ctx context.Context, cfg *models.EdgeOnboardingConfig, database db.Service, log logger.Logger) (*edgeOnboardingService, error) {
	if cfg == nil || !cfg.Enabled {
		return nil, nil
	}

	keyBytes, err := base64.StdEncoding.DecodeString(cfg.EncryptionKey)
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: decode encryption key: %w", err)
	}

	cipher, err := secrets.NewCipher(keyBytes)
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: init cipher: %w", err)
	}

	service := &edgeOnboardingService{
		cfg:     cfg,
		db:      database,
		logger:  log,
		cipher:  cipher,
		allowed: make(map[string]struct{}),
	}

	if err := service.refreshAllowedPollers(ctx); err != nil {
		return nil, err
	}

	return service, nil
}

func (s *edgeOnboardingService) refreshAllowedPollers(ctx context.Context) error {
	if s == nil {
		return nil
	}

	ids, err := s.db.ListEdgeOnboardingPollerIDs(ctx, onboardingAllowedStatuses...)
	if err != nil {
		return fmt.Errorf("edge onboarding: list poller ids: %w", err)
	}

	next := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		next[id] = struct{}{}
	}

	s.mu.Lock()
	s.allowed = next
	s.mu.Unlock()

	return nil
}

func (s *edgeOnboardingService) allowedPollersSnapshot() []string {
	if s == nil {
		return nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	pollers := make([]string, 0, len(s.allowed))
	for id := range s.allowed {
		pollers = append(pollers, id)
	}

	return pollers
}

func (s *edgeOnboardingService) isPollerAllowed(ctx context.Context, pollerID string) bool {
	if s == nil {
		return false
	}

	s.mu.RLock()
	_, ok := s.allowed[pollerID]
	s.mu.RUnlock()
	if ok {
		return true
	}

	if err := s.refreshAllowedPollers(ctx); err != nil {
		s.logger.Warn().
			Err(err).
			Msg("edge onboarding: failed to refresh poller cache during lookup")

		return false
	}

	s.mu.RLock()
	_, ok = s.allowed[pollerID]
	s.mu.RUnlock()
	return ok
}

func (s *edgeOnboardingService) cipherInstance() *secrets.Cipher {
	if s == nil {
		return nil
	}

	return s.cipher
}

func (s *edgeOnboardingService) ListPackages(ctx context.Context, filter *models.EdgeOnboardingListFilter) ([]*models.EdgeOnboardingPackage, error) {
	if s == nil {
		return nil, errEdgeOnboardingDisabled
	}
	if filter == nil {
		filter = &models.EdgeOnboardingListFilter{}
	}
	packages, err := s.db.ListEdgeOnboardingPackages(ctx, filter)
	if err != nil {
		return nil, err
	}
	return packages, nil
}

func (s *edgeOnboardingService) GetPackage(ctx context.Context, packageID string) (*models.EdgeOnboardingPackage, error) {
	if s == nil {
		return nil, errEdgeOnboardingDisabled
	}
	return s.db.GetEdgeOnboardingPackage(ctx, packageID)
}

func (s *edgeOnboardingService) ListEvents(ctx context.Context, packageID string, limit int) ([]*models.EdgeOnboardingEvent, error) {
	if s == nil {
		return nil, errEdgeOnboardingDisabled
	}
	return s.db.ListEdgeOnboardingEvents(ctx, packageID, limit)
}
