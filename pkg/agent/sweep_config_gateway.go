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
	ID            string                `json:"id"`
	SweepGroupID  string                `json:"sweep_group_id"`
	Targets       []string              `json:"targets"`
	Ports         []int                 `json:"ports"`
	Modes         []string              `json:"modes"`
	Schedule      gatewaySweepSchedule  `json:"schedule"`
	Settings      gatewaySweepSettings  `json:"settings"`
	DeviceTargets []gatewayDeviceTarget `json:"device_targets,omitempty"`
}

type gatewayDeviceTarget struct {
	Network    string            `json:"network"`
	SweepModes []string          `json:"sweep_modes,omitempty"`
	QueryLabel string            `json:"query_label,omitempty"`
	Source     string            `json:"source,omitempty"`
	Metadata   map[string]string `json:"metadata,omitempty"`
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

func parseGatewaySweepConfig(configJSON []byte, log logger.Logger) (*SweepGroupsConfig, error) {
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
		return &SweepGroupsConfig{ConfigHash: sweep.ConfigHash}, nil
	}

	config := &SweepGroupsConfig{
		ConfigHash: sweep.ConfigHash,
		Groups:     make([]SweepGroupConfig, 0, len(sweep.Groups)),
	}

	for _, group := range sweep.Groups {
		sweepGroupID := group.SweepGroupID
		if sweepGroupID == "" {
			sweepGroupID = group.ID
		}

		groupConfig := SweepGroupConfig{
			ID:             group.ID,
			SweepGroupID:   sweepGroupID,
			Networks:       normalizeTargets(group.Targets, log),
			Ports:          group.Ports,
			SweepModes:     parseSweepModes(group.Modes, log),
			DeviceTargets:  convertDeviceTargets(group.DeviceTargets, log),
			Concurrency:    group.Settings.Concurrency,
			ScheduleType:   strings.ToLower(strings.TrimSpace(group.Schedule.Type)),
			CronExpression: strings.TrimSpace(group.Schedule.Cron),
			ConfigHash:     sweep.ConfigHash,
		}

		if interval, ok := parseScheduleInterval(group.Schedule, log); ok {
			groupConfig.Interval = interval
		}

		if timeout, err := parseDurationValue(group.Settings.Timeout); err == nil {
			groupConfig.Timeout = timeout
		} else if group.Settings.Timeout != "" {
			log.Warn().Err(err).Str("timeout", group.Settings.Timeout).Msg("Invalid sweep timeout")
		}

		config.Groups = append(config.Groups, groupConfig)
	}

	return config, nil
}

func parseScheduleInterval(schedule gatewaySweepSchedule, log logger.Logger) (Duration, bool) {
	switch strings.ToLower(strings.TrimSpace(schedule.Type)) {
	case "", intervalLiteral:
		if schedule.Interval == "" {
			return 0, false
		}

		interval, err := parseDurationValue(schedule.Interval)
		if err != nil {
			log.Warn().Err(err).Str(intervalLiteral, schedule.Interval).Msg("Invalid sweep interval")
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

func convertDeviceTargets(targets []gatewayDeviceTarget, log logger.Logger) []models.DeviceTarget {
	if len(targets) == 0 {
		return nil
	}

	converted := make([]models.DeviceTarget, 0, len(targets))
	for _, t := range targets {
		network := strings.TrimSpace(t.Network)
		if network == "" {
			continue
		}

		// Normalize to CIDR if it's a plain IP
		if !strings.Contains(network, "/") {
			if ip := net.ParseIP(network); ip != nil {
				network += "/32"
			} else {
				log.Warn().Str("network", t.Network).Msg("Skipping invalid device target network")
				continue
			}
		}

		converted = append(converted, models.DeviceTarget{
			Network:    network,
			SweepModes: parseSweepModes(t.SweepModes, log),
			QueryLabel: t.QueryLabel,
			Source:     t.Source,
			Metadata:   t.Metadata,
		})
	}

	return converted
}
