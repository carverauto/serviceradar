/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/sweeper"
	"github.com/carverauto/serviceradar/proto"
)

const defaultSweepGroupID = "default"

var errSweepServerConfigRequired = errors.New("server config is required")

// MultiSweepService manages multiple sweep groups and schedules them independently.
type MultiSweepService struct {
	mu             sync.RWMutex
	groups         map[string]*SweepService
	groupConfigs   map[string]SweepGroupConfig
	groupSequences map[string]string
	groupOrder     []string
	nextIndex      int
	configHash     string
	started        bool
	startCtx       context.Context
	logger         logger.Logger
	serverConfig   *ServerConfig
	sweepOptions   []sweeper.Option
}

// NewMultiSweepService creates a new MultiSweepService from sweep group configs.
func NewMultiSweepService(
	cfg *ServerConfig,
	groups []SweepGroupConfig,
	log logger.Logger,
	opts ...sweeper.Option,
) (*MultiSweepService, error) {
	return NewMultiSweepServiceWithContext(context.Background(), cfg, groups, log, opts...)
}

// NewMultiSweepServiceWithContext creates a MultiSweepService using ctx for
// initial service replacement work.
func NewMultiSweepServiceWithContext(
	ctx context.Context,
	cfg *ServerConfig,
	groups []SweepGroupConfig,
	log logger.Logger,
	opts ...sweeper.Option,
) (*MultiSweepService, error) {
	service := &MultiSweepService{
		groups:         make(map[string]*SweepService),
		groupConfigs:   make(map[string]SweepGroupConfig),
		groupSequences: make(map[string]string),
		groupOrder:     []string{},
		configHash:     "",
		logger:         log,
		serverConfig:   cfg,
		sweepOptions:   append([]sweeper.Option(nil), opts...),
	}

	if cfg == nil {
		return nil, errSweepServerConfigRequired
	}

	if len(groups) == 0 {
		return service, nil
	}

	if err := service.UpdateSweepGroupsContext(ctx, &SweepGroupsConfig{Groups: groups, ConfigHash: groups[0].ConfigHash}); err != nil {
		return nil, err
	}

	return service, nil
}

// Name returns the service name.
func (*MultiSweepService) Name() string {
	return networkSweepServiceName
}

// Start begins all sweep group services.
func (s *MultiSweepService) Start(ctx context.Context) error {
	s.mu.Lock()
	if s.started {
		s.mu.Unlock()
		return nil
	}
	s.started = true
	s.startCtx = ctx
	groupServices := make([]*SweepService, 0, len(s.groups))
	for _, svc := range s.groups {
		groupServices = append(groupServices, svc)
	}
	s.mu.Unlock()

	for _, svc := range groupServices {
		go func(svc *SweepService) {
			if err := svc.Start(ctx); err != nil {
				s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to start sweep group service")
			}
		}(svc)
	}

	<-ctx.Done()
	return ctx.Err()
}

// Stop gracefully stops all sweep group services.
func (s *MultiSweepService) Stop(ctx context.Context) error {
	s.mu.Lock()
	groupServices := make([]*SweepService, 0, len(s.groups))
	for _, svc := range s.groups {
		groupServices = append(groupServices, svc)
	}
	s.started = false
	s.startCtx = nil
	s.mu.Unlock()

	for _, svc := range groupServices {
		if err := svc.Stop(ctx); err != nil {
			s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to stop sweep group service")
		}
	}

	return nil
}

// RunSweepGroup triggers a single sweep for the specified group.
func (s *MultiSweepService) RunSweepGroup(ctx context.Context, groupID string) error {
	if groupID == "" {
		return errSweepGroupIDRequired
	}

	s.mu.RLock()
	svc := s.groups[groupID]
	s.mu.RUnlock()

	if svc == nil {
		return errSweepGroupNotFound
	}

	return svc.RunOnce(ctx)
}

// AcknowledgeSweepResults marks a group's results sequence as delivered after
// the push loop has successfully streamed every chunk to the gateway.
func (s *MultiSweepService) AcknowledgeSweepResults(groupID string, sequence string) {
	if groupID == "" || sequence == "" {
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if _, ok := s.groups[groupID]; !ok {
		return
	}

	s.groupSequences[groupID] = sequence
}

// UpdateConfig updates the sweep config, treating it as a single group.
func (s *MultiSweepService) UpdateConfig(config *models.Config) error {
	if config == nil {
		return nil
	}

	groupID := config.SweepGroupID
	if groupID == "" {
		groupID = defaultSweepGroupID
	}

	groupConfig := SweepGroupConfig{
		ID:            groupID,
		SweepGroupID:  groupID,
		Networks:      config.Networks,
		Ports:         config.Ports,
		SweepModes:    config.SweepModes,
		DeviceTargets: config.DeviceTargets,
		BannerGrab:    fromModelBannerGrab(config.BannerGrab),
		Interval:      Duration(config.Interval),
		Concurrency:   config.Concurrency,
		Timeout:       Duration(config.Timeout),
		ScheduleType:  intervalLiteral,
		ConfigHash:    config.ConfigHash,
	}

	return s.UpdateSweepGroupsContext(context.TODO(), &SweepGroupsConfig{Groups: []SweepGroupConfig{groupConfig}, ConfigHash: config.ConfigHash})
}

// UpdateSweepGroups updates sweep group configs, creating or removing per-group services as needed.
func (s *MultiSweepService) UpdateSweepGroups(config *SweepGroupsConfig) error {
	return s.UpdateSweepGroupsContext(context.TODO(), config)
}

// UpdateSweepGroupsContext updates sweep group configs, creating or removing
// per-group services as needed.
func (s *MultiSweepService) UpdateSweepGroupsContext(ctx context.Context, config *SweepGroupsConfig) error {
	if config == nil {
		return nil
	}

	newGroups := make(map[string]SweepGroupConfig, len(config.Groups))
	for _, group := range config.Groups {
		groupID := group.SweepGroupID
		if groupID == "" {
			groupID = group.ID
		}
		if groupID == "" {
			s.logger.Warn().Msg("Skipping sweep group with empty ID")
			continue
		}

		if !isSweepGroupScheduleSupported(group, s.logger) {
			s.logger.Warn().Str("sweep_group_id", groupID).Msg("Skipping sweep group with unsupported schedule")
			continue
		}

		group.SweepGroupID = groupID
		newGroups[groupID] = group
	}

	s.mu.RLock()
	existingGroups := make(map[string]*SweepService, len(s.groups))
	for groupID, svc := range s.groups {
		existingGroups[groupID] = svc
	}
	started := s.started
	startCtx := s.startCtx
	s.mu.RUnlock()

	if ctx == nil {
		ctx = startCtx
	}
	if ctx == nil {
		ctx = context.Background()
	}

	toStop := make(map[string]*SweepService)
	for groupID, svc := range existingGroups {
		if _, ok := newGroups[groupID]; !ok {
			toStop[groupID] = svc
		}
	}

	for groupID, svc := range toStop {
		if err := svc.Stop(ctx); err != nil {
			s.logger.Error().Err(err).Str("sweep_group_id", groupID).Msg("Failed to stop sweep group service")
		}
	}

	createdGroups := make(map[string]*SweepService)
	for groupID, group := range newGroups {
		group.ConfigHash = config.ConfigHash
		modelConfig, err := buildSweepModelConfigFromGroup(s.serverConfig, group, s.logger)
		if err != nil {
			s.logger.Error().Err(err).Str("sweep_group_id", groupID).Msg("Failed to build sweep model config")
			continue
		}

		if svc, ok := existingGroups[groupID]; ok {
			if err := svc.UpdateConfig(modelConfig); err != nil {
				s.logger.Error().Err(err).Str("sweep_group_id", groupID).Msg("Failed to update sweep group config")
			}
			continue
		}

		sweepSvc, err := NewSweepService(modelConfig, s.logger, s.sweepOptions...)
		if err != nil {
			s.logger.Error().Err(err).Str("sweep_group_id", groupID).Msg("Failed to create sweep group service")
			continue
		}
		sweepService, ok := sweepSvc.(*SweepService)
		if !ok {
			s.logger.Error().Str("sweep_group_id", groupID).Msg("Unexpected sweep service type")
			continue
		}
		createdGroups[groupID] = sweepService
	}

	s.mu.Lock()
	for groupID := range toStop {
		delete(s.groups, groupID)
		delete(s.groupConfigs, groupID)
		delete(s.groupSequences, groupID)
	}
	for groupID, group := range newGroups {
		group.ConfigHash = config.ConfigHash
		s.groupConfigs[groupID] = group
	}
	for groupID, svc := range createdGroups {
		s.groups[groupID] = svc
		s.groupSequences[groupID] = ""
	}
	s.configHash = config.ConfigHash
	s.groupOrder = sortedGroupIDs(newGroups)
	if s.nextIndex >= len(s.groupOrder) {
		s.nextIndex = 0
	}
	s.mu.Unlock()

	if started && startCtx != nil {
		for groupID, svc := range createdGroups {
			go func(svc *SweepService, groupID string) {
				if err := svc.Start(startCtx); err != nil {
					s.logger.Error().Err(err).Str("sweep_group_id", groupID).Msg("Failed to start sweep group service")
				}
			}(svc, groupID)
		}
	}

	return nil
}

// GetSweepResults returns sweep results for the next group that has new data.
func (s *MultiSweepService) GetSweepResults(ctx context.Context, _ string) (*proto.ResultsResponse, error) {
	s.mu.RLock()
	groupOrder := append([]string(nil), s.groupOrder...)
	groups := make(map[string]*SweepService, len(s.groups))
	sequences := make(map[string]string, len(s.groupSequences))
	for id, svc := range s.groups {
		groups[id] = svc
	}
	for id, seq := range s.groupSequences {
		sequences[id] = seq
	}
	startIndex := s.nextIndex
	s.mu.RUnlock()

	if len(groupOrder) == 0 {
		return &proto.ResultsResponse{
			HasNewData:      false,
			CurrentSequence: s.aggregateSequence(),
			ServiceName:     networkSweepServiceName,
			ServiceType:     "sweep",
			Available:       false,
			Timestamp:       time.Now().Unix(),
		}, nil
	}

	for i := 0; i < len(groupOrder); i++ {
		idx := (startIndex + i) % len(groupOrder)
		groupID := groupOrder[idx]
		svc := groups[groupID]
		if svc == nil {
			continue
		}

		lastSeq := sequences[groupID]
		response, err := svc.GetSweepResults(ctx, lastSeq)
		if err != nil {
			s.logger.Warn().Err(err).Str("sweep_group_id", groupID).Msg("Failed to get sweep results")
			continue
		}

		if response == nil {
			continue
		}

		if response.HasNewData && len(response.Data) > 0 {
			if response.SweepGroupId == "" {
				response.SweepGroupId = groupID
			}

			s.mu.Lock()
			s.nextIndex = (idx + 1) % len(groupOrder)
			s.mu.Unlock()

			return response, nil
		}
	}

	return &proto.ResultsResponse{
		HasNewData:      false,
		CurrentSequence: s.aggregateSequence(),
		ServiceName:     networkSweepServiceName,
		ServiceType:     "sweep",
		Available:       true,
		Timestamp:       time.Now().Unix(),
	}, nil
}

// GetConfigHash returns the current config hash for change detection.
func (s *MultiSweepService) GetConfigHash() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.configHash
}

// GetStatus returns a status response for the most recent sweep group.
func (s *MultiSweepService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
	status, _, err := s.GetStatusWithMetricPayload(ctx)
	return status, err
}

// GetStatusWithMetricPayload returns the best group status plus typed data for
// sweep metric envelope construction without reparsing the JSON status payload.
func (s *MultiSweepService) GetStatusWithMetricPayload(ctx context.Context) (*proto.StatusResponse, map[string]any, error) {
	s.mu.RLock()
	groupOrder := append([]string(nil), s.groupOrder...)
	groups := make(map[string]*SweepService, len(s.groups))
	for id, svc := range s.groups {
		groups[id] = svc
	}
	s.mu.RUnlock()

	if len(groupOrder) == 0 {
		payload, _ := json.Marshal(map[string]string{
			"reason": "no_sweep_groups_configured",
		})

		s.logger.Warn().Msg("No sweep groups configured; reporting sweep status as unavailable")

		return &proto.StatusResponse{
			Available:    false,
			Message:      payload,
			ServiceName:  networkSweepServiceName,
			ServiceType:  "sweep",
			ResponseTime: 0,
		}, nil, nil
	}

	var bestStatus *proto.StatusResponse
	var bestMetricPayload map[string]any
	var bestLastSweep int64

	for _, groupID := range groupOrder {
		svc := groups[groupID]
		if svc == nil {
			continue
		}

		status, metricPayload, err := svc.GetStatusWithMetricPayload(ctx)
		if err != nil || status == nil {
			continue
		}

		lastSweep := sweepMetricPayloadLastSweep(metricPayload)
		if bestStatus == nil || lastSweep > bestLastSweep {
			bestStatus = status
			bestMetricPayload = metricPayload
			bestLastSweep = lastSweep
		}
	}

	if bestStatus == nil {
		payload, _ := json.Marshal(map[string]string{
			"reason": "no_sweep_status_available",
		})

		s.logger.Warn().Msg("Sweep status unavailable for all sweep groups")

		return &proto.StatusResponse{
			Available:    false,
			Message:      payload,
			ServiceName:  networkSweepServiceName,
			ServiceType:  "sweep",
			ResponseTime: 0,
		}, nil, nil
	}

	return bestStatus, bestMetricPayload, nil
}

func sweepMetricPayloadLastSweep(payload map[string]any) int64 {
	if payload == nil {
		return 0
	}
	if value, ok := intLikeFromAny(payload["last_sweep"]); ok {
		return value
	}
	return 0
}

func (s *MultiSweepService) GetBannerGrabStats() *models.BannerGrabStats {
	s.mu.RLock()
	groups := make([]*SweepService, 0, len(s.groups))
	for _, svc := range s.groups {
		groups = append(groups, svc)
	}
	s.mu.RUnlock()

	var out models.BannerGrabStats
	found := false
	for _, svc := range groups {
		if svc == nil {
			continue
		}
		stats := svc.GetBannerGrabStats()
		if stats == nil {
			continue
		}

		found = true
		out.CandidatesTotal += stats.CandidatesTotal
		out.ProbesTotal += stats.ProbesTotal
		out.InFlight += stats.InFlight
		out.QueueDepth += stats.QueueDepth
		out.MatchBatchesTotal += stats.MatchBatchesTotal
		out.MatchBatchBytesTotal += stats.MatchBatchBytesTotal
		out.BannerBytesTotal += stats.BannerBytesTotal
		out.SkippedFreshTotal += stats.SkippedFreshTotal
		out.SkippedBackoffTotal += stats.SkippedBackoffTotal
		out.MatchesTotal += stats.MatchesTotal
		out.EmptyResponseTotal += stats.EmptyResponseTotal
		out.ConnectionResetTotal += stats.ConnectionResetTotal
		out.TimeoutTotal += stats.TimeoutTotal
		out.ErrorsTotal += stats.ErrorsTotal
	}
	if !found {
		return nil
	}

	return &out
}

func (s *MultiSweepService) BannerGrabEnabled() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for _, group := range s.groupConfigs {
		if group.BannerGrab.Enabled {
			return true
		}
	}

	return false
}

func sortedGroupIDs(groups map[string]SweepGroupConfig) []string {
	ids := make([]string, 0, len(groups))
	for id := range groups {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func isSweepGroupScheduleSupported(group SweepGroupConfig, log logger.Logger) bool {
	scheduleType := group.ScheduleType
	if scheduleType == "" {
		scheduleType = intervalLiteral
	}

	switch scheduleType {
	case intervalLiteral:
		if time.Duration(group.Interval) <= 0 {
			log.Warn().Str("sweep_group_id", group.SweepGroupID).Msg("Sweep group interval is missing or invalid")
			return false
		}
		return true
	case "cron":
		log.Warn().Str("sweep_group_id", group.SweepGroupID).Msg("Cron schedules are not supported for agent sweeps yet")
		return false
	default:
		log.Warn().Str("sweep_group_id", group.SweepGroupID).Str("schedule_type", scheduleType).Msg("Unknown sweep schedule type")
		return false
	}
}

func (s *MultiSweepService) aggregateSequence() string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(s.groupSequences) == 0 {
		return ""
	}

	ids := make([]string, 0, len(s.groupSequences))
	for id := range s.groupSequences {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	parts := make([]string, 0, len(ids))
	for _, id := range ids {
		parts = append(parts, id+":"+s.groupSequences[id])
	}

	sum := sha256.Sum256([]byte(strings.Join(parts, "|")))
	return hex.EncodeToString(sum[:8])
}
