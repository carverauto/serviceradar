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

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
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
	BannerGrab    gatewayBannerGrab     `json:"banner_grab"`
	Schedule      gatewaySweepSchedule  `json:"schedule"`
	Settings      gatewaySweepSettings  `json:"settings"`
	DeviceTargets []gatewayDeviceTarget `json:"device_targets,omitempty"`
}

type gatewayBannerGrab struct {
	Enabled                bool             `json:"enabled"`
	Protocols              []string         `json:"protocols"`
	Ports                  map[string][]int `json:"ports"`
	ConnectTimeoutMS       *int             `json:"connect_timeout_ms"`
	ReadTimeoutMS          *int             `json:"read_timeout_ms"`
	MaxBannerBytes         *int             `json:"max_banner_bytes"`
	MaxConcurrencyPerHost  *int             `json:"max_concurrency_per_host"`
	MaxGlobalConcurrency   *int             `json:"max_global_concurrency"`
	MaxProbeRatePerSecond  *int             `json:"max_probe_rate_per_second"`
	MaxCandidateQueue      *int             `json:"max_candidate_queue"`
	MatchBatchSize         *int             `json:"match_batch_size"`
	MatchBatchMaxBytes     *int             `json:"match_batch_max_bytes"`
	MinReprobeIntervalSec  *int             `json:"min_reprobe_interval_s"`
	PerHostRateLimitMillis *int             `json:"per_host_rate_limit_ms"`
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
			BannerGrab:     normalizeBannerGrab(group.BannerGrab),
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

func defaultBannerGrabConfig() BannerGrabConfig {
	return BannerGrabConfig{
		Enabled:                false,
		Protocols:              []string{},
		Ports:                  map[string][]int{},
		ConnectTimeoutMS:       2000,
		ReadTimeoutMS:          2000,
		MaxBannerBytes:         1024,
		MaxConcurrencyPerHost:  4,
		MaxGlobalConcurrency:   256,
		MaxProbeRatePerSecond:  0,
		MaxCandidateQueue:      8192,
		MatchBatchSize:         256,
		MatchBatchMaxBytes:     1048576,
		MinReprobeIntervalSec:  86400,
		PerHostRateLimitMillis: 100,
	}
}

func normalizeBannerGrab(raw gatewayBannerGrab) BannerGrabConfig {
	config := defaultBannerGrabConfig()
	config.Enabled = raw.Enabled
	config.Protocols = normalizeBannerProtocols(raw.Protocols)
	config.Ports = normalizeBannerPorts(raw.Ports)
	config.ConnectTimeoutMS = positiveOrDefault(raw.ConnectTimeoutMS, config.ConnectTimeoutMS)
	config.ReadTimeoutMS = positiveOrDefault(raw.ReadTimeoutMS, config.ReadTimeoutMS)
	config.MaxBannerBytes = positiveOrDefault(raw.MaxBannerBytes, config.MaxBannerBytes)
	config.MaxConcurrencyPerHost = positiveOrDefault(raw.MaxConcurrencyPerHost, config.MaxConcurrencyPerHost)
	config.MaxGlobalConcurrency = positiveOrDefault(raw.MaxGlobalConcurrency, config.MaxGlobalConcurrency)
	config.MaxProbeRatePerSecond = nonNegativeOrDefault(raw.MaxProbeRatePerSecond, config.MaxProbeRatePerSecond)
	config.MaxCandidateQueue = positiveOrDefault(raw.MaxCandidateQueue, config.MaxCandidateQueue)
	config.MatchBatchSize = positiveOrDefault(raw.MatchBatchSize, config.MatchBatchSize)
	config.MatchBatchMaxBytes = positiveOrDefault(raw.MatchBatchMaxBytes, config.MatchBatchMaxBytes)
	config.MinReprobeIntervalSec = nonNegativeOrDefault(raw.MinReprobeIntervalSec, config.MinReprobeIntervalSec)
	config.PerHostRateLimitMillis = nonNegativeOrDefault(raw.PerHostRateLimitMillis, config.PerHostRateLimitMillis)

	return config
}

func normalizeBannerProtocols(protocols []string) []string {
	allowed := map[string]struct{}{
		"ssh": {}, "http": {}, "smb": {}, "ftp": {}, "telnet": {}, "smtp": {}, "ntp": {}, "dns": {}, "rdp": {},
	}
	seen := make(map[string]struct{}, len(protocols))
	normalized := make([]string, 0, len(protocols))

	for _, protocol := range protocols {
		protocol = strings.ToLower(strings.TrimSpace(protocol))
		if _, ok := allowed[protocol]; !ok {
			continue
		}
		if _, ok := seen[protocol]; ok {
			continue
		}
		seen[protocol] = struct{}{}
		normalized = append(normalized, protocol)
	}

	return normalized
}

func normalizeBannerPorts(ports map[string][]int) map[string][]int {
	if len(ports) == 0 {
		return map[string][]int{}
	}

	normalized := make(map[string][]int, len(ports))
	for protocol, values := range ports {
		protocol = strings.ToLower(strings.TrimSpace(protocol))
		if protocol == "" {
			continue
		}
		normalized[protocol] = normalizeBannerPortList(values)
	}

	return normalized
}

func normalizeBannerPortList(values []int) []int {
	seen := make(map[int]struct{}, len(values))
	normalized := make([]int, 0, len(values))

	for _, port := range values {
		if port < 1 || port > 65535 {
			continue
		}
		if _, ok := seen[port]; ok {
			continue
		}
		seen[port] = struct{}{}
		normalized = append(normalized, port)
	}

	return normalized
}

func positiveOrDefault(value *int, fallback int) int {
	if value != nil && *value > 0 {
		return *value
	}

	return fallback
}

func nonNegativeOrDefault(value *int, fallback int) int {
	if value != nil && *value >= 0 {
		return *value
	}

	return fallback
}

func toModelBannerGrab(config BannerGrabConfig) models.BannerGrab {
	return models.BannerGrab{
		Enabled:                config.Enabled,
		Protocols:              append([]string(nil), config.Protocols...),
		Ports:                  cloneBannerPorts(config.Ports),
		ConnectTimeoutMS:       config.ConnectTimeoutMS,
		ReadTimeoutMS:          config.ReadTimeoutMS,
		MaxBannerBytes:         config.MaxBannerBytes,
		MaxConcurrencyPerHost:  config.MaxConcurrencyPerHost,
		MaxGlobalConcurrency:   config.MaxGlobalConcurrency,
		MaxProbeRatePerSecond:  config.MaxProbeRatePerSecond,
		MaxCandidateQueue:      config.MaxCandidateQueue,
		MatchBatchSize:         config.MatchBatchSize,
		MatchBatchMaxBytes:     config.MatchBatchMaxBytes,
		MinReprobeIntervalSec:  config.MinReprobeIntervalSec,
		PerHostRateLimitMillis: config.PerHostRateLimitMillis,
	}
}

func fromModelBannerGrab(config models.BannerGrab) BannerGrabConfig {
	return BannerGrabConfig{
		Enabled:                config.Enabled,
		Protocols:              append([]string(nil), config.Protocols...),
		Ports:                  cloneBannerPorts(config.Ports),
		ConnectTimeoutMS:       config.ConnectTimeoutMS,
		ReadTimeoutMS:          config.ReadTimeoutMS,
		MaxBannerBytes:         config.MaxBannerBytes,
		MaxConcurrencyPerHost:  config.MaxConcurrencyPerHost,
		MaxGlobalConcurrency:   config.MaxGlobalConcurrency,
		MaxProbeRatePerSecond:  config.MaxProbeRatePerSecond,
		MaxCandidateQueue:      config.MaxCandidateQueue,
		MatchBatchSize:         config.MatchBatchSize,
		MatchBatchMaxBytes:     config.MatchBatchMaxBytes,
		MinReprobeIntervalSec:  config.MinReprobeIntervalSec,
		PerHostRateLimitMillis: config.PerHostRateLimitMillis,
	}
}

func cloneBannerPorts(ports map[string][]int) map[string][]int {
	if len(ports) == 0 {
		return map[string][]int{}
	}

	cloned := make(map[string][]int, len(ports))
	for protocol, values := range ports {
		cloned[protocol] = append([]int(nil), values...)
	}

	return cloned
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

		network, ok := normalizeSweepNetwork(target, log)
		if ok {
			normalized = append(normalized, network)
			continue
		}

		if !strings.Contains(target, "/") {
			log.Warn().Str("target", target).Msg("Skipping invalid sweep target")
		}
	}

	return normalized
}

func normalizeSweepNetwork(network string, log logger.Logger) (string, bool) {
	if strings.Contains(network, "/") {
		if _, _, err := net.ParseCIDR(network); err != nil {
			log.Warn().Err(err).Str("network", network).Msg("Skipping invalid sweep CIDR")
			return "", false
		}

		return network, true
	}

	ip := net.ParseIP(network)
	if ip == nil {
		return "", false
	}

	if ipv4 := ip.To4(); ipv4 != nil {
		return ipv4.String() + "/32", true
	}

	return ip.String() + "/128", true
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
		case string(models.ModeMTR):
			parsed = append(parsed, models.ModeMTR)
		case "arp", "":
			// Scanner profiles historically offered ARP. The sweeper has no ARP
			// engine, so drop it without a warning that looks like a fault.
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

		normalized, ok := normalizeSweepNetwork(network, log)
		if !ok {
			if !strings.Contains(network, "/") {
				log.Warn().Str("network", t.Network).Msg("Skipping invalid device target network")
			}

			continue
		}

		converted = append(converted, models.DeviceTarget{
			Network:    normalized,
			SweepModes: parseSweepModes(t.SweepModes, log),
			QueryLabel: t.QueryLabel,
			Source:     t.Source,
			Metadata:   t.Metadata,
		})
	}

	return converted
}
