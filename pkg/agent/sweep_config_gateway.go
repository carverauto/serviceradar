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
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

type gatewayConfigPayload struct {
	Sweep json.RawMessage `json:"sweep"`
}

type gatewaySweepConfig struct {
	Groups     []gatewaySweepGroup `json:"groups"`
	ConfigHash string              `json:"config_hash"`
}

type gatewaySweepGroup struct {
	ID           string               `json:"id"`
	SweepGroupID string               `json:"sweep_group_id"`
	Targets      []string             `json:"targets"`
	Ports        []int                `json:"ports"`
	Modes        []string             `json:"modes"`
	Schedule     gatewaySweepSchedule `json:"schedule"`
	Settings     gatewaySweepSettings `json:"settings"`
}

type gatewaySweepSchedule struct {
	Type     string `json:"type"`
	Interval string `json:"interval"`
	Cron     string `json:"cron"`
}

type gatewaySweepSettings struct {
	Concurrency int    `json:"concurrency"`
	Timeout     string `json:"timeout"`
}

func parseGatewaySweepConfig(configJSON []byte, log logger.Logger) (*SweepConfig, error) {
	if len(configJSON) == 0 {
		return nil, nil
	}

	var payload gatewayConfigPayload
	if err := json.Unmarshal(configJSON, &payload); err != nil {
		return nil, fmt.Errorf("decode gateway payload: %w", err)
	}

	if len(payload.Sweep) == 0 {
		return nil, nil
	}

	var sweep gatewaySweepConfig
	if err := json.Unmarshal(payload.Sweep, &sweep); err != nil {
		return nil, fmt.Errorf("decode sweep payload: %w", err)
	}

	if len(sweep.Groups) == 0 {
		log.Info().Msg("Gateway sweep config contained no groups; clearing sweep targets")
		return &SweepConfig{ConfigHash: sweep.ConfigHash}, nil
	}

	group := sweep.Groups[0]
	if len(sweep.Groups) > 1 {
		log.Warn().
			Int("group_count", len(sweep.Groups)).
			Msg("Gateway sweep config contains multiple groups; using first group only")
	}

	sweepGroupID := group.SweepGroupID
	if sweepGroupID == "" {
		sweepGroupID = group.ID
	}

	config := &SweepConfig{
		Networks:     normalizeTargets(group.Targets, log),
		Ports:        group.Ports,
		SweepModes:   parseSweepModes(group.Modes, log),
		Concurrency:  group.Settings.Concurrency,
		SweepGroupID: sweepGroupID,
		ConfigHash:   sweep.ConfigHash,
	}

	if interval, ok := parseScheduleInterval(group.Schedule, log); ok {
		config.Interval = interval
	}

	if timeout, err := parseDurationValue(group.Settings.Timeout); err == nil {
		config.Timeout = timeout
	} else if group.Settings.Timeout != "" {
		log.Warn().Err(err).Str("timeout", group.Settings.Timeout).Msg("Invalid sweep timeout")
	}

	return config, nil
}

func parseScheduleInterval(schedule gatewaySweepSchedule, log logger.Logger) (Duration, bool) {
	switch strings.ToLower(strings.TrimSpace(schedule.Type)) {
	case "", "interval":
		if schedule.Interval == "" {
			return 0, false
		}

		interval, err := parseDurationValue(schedule.Interval)
		if err != nil {
			log.Warn().Err(err).Str("interval", schedule.Interval).Msg("Invalid sweep interval")
			return 0, false
		}

		return interval, true
	case "cron":
		log.Warn().Str("cron", schedule.Cron).Msg("Cron schedules are not supported for agent sweeps yet")
		return 0, false
	default:
		log.Warn().Str("schedule_type", schedule.Type).Msg("Unknown sweep schedule type")
		return 0, false
	}
}

func parseDurationValue(raw string) (Duration, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0, nil
	}

	duration, err := time.ParseDuration(raw)
	if err != nil {
		return 0, err
	}

	return Duration(duration), nil
}

func normalizeTargets(targets []string, log logger.Logger) []string {
	normalized := make([]string, 0, len(targets))
	for _, target := range targets {
		target = strings.TrimSpace(target)
		if target == "" {
			continue
		}

		if strings.Contains(target, "/") {
			normalized = append(normalized, target)
			continue
		}

		if ip := net.ParseIP(target); ip != nil {
			normalized = append(normalized, target+"/32")
			continue
		}

		log.Warn().Str("target", target).Msg("Skipping invalid sweep target")
	}

	return normalized
}

func parseSweepModes(modes []string, log logger.Logger) []models.SweepMode {
	parsed := make([]models.SweepMode, 0, len(modes))
	for _, mode := range modes {
		switch strings.ToLower(strings.TrimSpace(mode)) {
		case string(models.ModeICMP):
			parsed = append(parsed, models.ModeICMP)
		case string(models.ModeTCP):
			parsed = append(parsed, models.ModeTCP)
		case string(models.ModeTCPConnect):
			parsed = append(parsed, models.ModeTCPConnect)
		case "":
			continue
		default:
			log.Warn().Str("mode", mode).Msg("Ignoring unknown sweep mode")
		}
	}

	return parsed
}
