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
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/sweeper"
)

var (
	errSweepTargetNotAddress  = errors.New("not an IP address, CIDR, or first-last range")
	errSweepRangeBound        = errors.New("range bound is not an IP address")
	errSweepRangeFamilies     = errors.New("range bounds are different address families")
	errSweepRangeReversed     = errors.New("range starts after it ends")
	errSweepRangeTooLarge     = errors.New("IPv6 range expands above the sweep target limit")
	errUnsupportedSweepFormat = errors.New("unsupported sweep config format")
	errSweepTargetSetMissing  = errors.New("sweep group references a missing device target set")
	errSweepDeviceRefMissing  = errors.New("sweep target set references a missing device table entry")
)

type gatewayConfigPayload struct {
	Sweep json.RawMessage `json:"sweep"`
}

type gatewaySweepConfig struct {
	Format      string                    `json:"format"`
	Groups      []gatewaySweepGroup       `json:"groups"`
	ConfigHash  string                    `json:"config_hash"`
	DeviceTable []gatewayDeviceTableEntry `json:"device_table"`
	TargetSets  []gatewayTargetSet        `json:"target_sets"`
}

type gatewaySweepGroup struct {
	ID              string                `json:"id"`
	SweepGroupID    string                `json:"sweep_group_id"`
	Name            string                `json:"name"`
	Targets         []string              `json:"targets"`
	Ports           []int                 `json:"ports"`
	Modes           []string              `json:"modes"`
	BannerGrab      gatewayBannerGrab     `json:"banner_grab"`
	Schedule        gatewaySweepSchedule  `json:"schedule"`
	Settings        gatewaySweepSettings  `json:"settings"`
	DeviceTargets   []gatewayDeviceTarget `json:"device_targets,omitempty"`
	DeviceTargetSet string                `json:"device_target_set"`
}

// gatewayDeviceTableEntry is one device in a shared-targets/v1 document,
// stored once however many target sets reference it.
type gatewayDeviceTableEntry struct {
	Ref       string `json:"ref"`
	IP        string `json:"ip"`
	DeviceUID string `json:"device_uid"`
}

// gatewayTargetSet is the per-query device list of a shared-targets/v1
// document, as refs into the device table.
type gatewayTargetSet struct {
	Key  string   `json:"key"`
	Refs []string `json:"refs"`
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
	ScanTimeout string `json:"scan_timeout,omitempty"`
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

	switch sweep.Format {
	case "":
		// Legacy format: device targets are embedded per group.
	case "shared-targets/v1":
		if err := rehydrateSharedTargets(&sweep); err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("%w: %q", errUnsupportedSweepFormat, sweep.Format)
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

		if scanTimeout, err := parseDurationValue(group.Settings.ScanTimeout); err == nil {
			groupConfig.MaxScanDuration = scanTimeout
		} else if group.Settings.ScanTimeout != "" {
			log.Warn().Err(err).Str("scan_timeout", group.Settings.ScanTimeout).Msg("Invalid sweep scan_timeout")
		}

		config.Groups = append(config.Groups, groupConfig)
	}

	return config, nil
}

// rehydrateSharedTargets expands a shared-targets/v1 document into the
// per-group device targets the legacy format embeds: for each group, one
// entry per ref of its target set, in set order, with the group's modes
// and name and source "srql" — field for field the legacy compiler output.
func rehydrateSharedTargets(sweep *gatewaySweepConfig) error {
	table := make(map[string]gatewayDeviceTableEntry, len(sweep.DeviceTable))
	for _, entry := range sweep.DeviceTable {
		table[entry.Ref] = entry
	}

	sets := make(map[string][]string, len(sweep.TargetSets))
	for _, set := range sweep.TargetSets {
		sets[set.Key] = set.Refs
	}

	for i := range sweep.Groups {
		group := &sweep.Groups[i]
		if group.DeviceTargetSet == "" {
			continue
		}

		refs, ok := sets[group.DeviceTargetSet]
		if !ok {
			return fmt.Errorf("%w: group %s names set %s", errSweepTargetSetMissing, group.ID, group.DeviceTargetSet)
		}

		targets := make([]gatewayDeviceTarget, 0, len(refs))
		for _, ref := range refs {
			entry, ok := table[ref]
			if !ok {
				return fmt.Errorf("%w: set %s names ref %s", errSweepDeviceRefMissing, group.DeviceTargetSet, ref)
			}

			metadata := map[string]string{}
			if entry.DeviceUID != "" {
				metadata["device_uid"] = entry.DeviceUID
			}

			targets = append(targets, gatewayDeviceTarget{
				Network:    entry.IP,
				SweepModes: group.Modes,
				QueryLabel: group.Name,
				Source:     "srql",
				Metadata:   metadata,
			})
		}

		group.DeviceTargets = targets
	}

	return nil
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
	case cronLiteral:
		log.Warn().Str(cronLiteral, schedule.Cron).Msg("Cron schedules are not supported for agent sweeps yet")
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

// normalizeTargets converts static targets into the CIDR entries the sweeper
// expands. An entry that cannot be read is dropped with one warning naming it.
func normalizeTargets(targets []string, log logger.Logger) []string {
	normalized := make([]string, 0, len(targets))
	for _, target := range targets {
		target = strings.TrimSpace(target)
		if target == "" {
			continue
		}

		networks, err := normalizeSweepNetwork(target)
		if err != nil {
			log.Warn().Err(err).Str("target", target).Msg("Skipping invalid sweep target")
			continue
		}

		normalized = append(normalized, networks...)
	}

	return normalized
}

// normalizeSweepNetwork returns the CIDR entries that sweep exactly the
// addresses of one target: a CIDR as written, a single IP as a host prefix, or
// an inclusive first-last range.
func normalizeSweepNetwork(network string) ([]string, error) {
	switch {
	case strings.Contains(network, "/"):
		if _, _, err := net.ParseCIDR(network); err != nil {
			return nil, err
		}

		return []string{network}, nil
	case strings.Contains(network, "-"):
		return sweepRangeNetworks(network)
	}

	ip := net.ParseIP(network)
	if ip == nil {
		return nil, errSweepTargetNotAddress
	}

	if ipv4 := ip.To4(); ipv4 != nil {
		return []string{ipv4.String() + "/32"}, nil
	}

	return []string{ip.String() + "/128"}, nil
}

// sweepRangeNetworks converts an inclusive first-last range into CIDR entries
// built from the fewest prefixes that hold it, not one entry per address. An
// IPv6 range is held to the limit the sweeper applies to one IPv6 network.
func sweepRangeNetworks(network string) ([]string, error) {
	firstText, lastText, _ := strings.Cut(network, "-")

	first, err := parseSweepRangeBound(firstText)
	if err != nil {
		return nil, err
	}

	last, err := parseSweepRangeBound(lastText)
	if err != nil {
		return nil, err
	}

	if first.Is4() != last.Is4() {
		return nil, errSweepRangeFamilies
	}

	if first.Compare(last) > 0 {
		return nil, errSweepRangeReversed
	}

	prefixes := rangePrefixes(first, last)
	if first.Is6() && prefixesExceed(prefixes, sweeper.MaxIPv6NetworkHosts) {
		return nil, fmt.Errorf("%w of %d addresses", errSweepRangeTooLarge, sweeper.MaxIPv6NetworkHosts)
	}

	return sweepNetworksForPrefixes(prefixes), nil
}

// parseSweepRangeBound parses one end of a range. An IPv4-mapped IPv6 bound
// reads as IPv4, as a single mapped IP does.
func parseSweepRangeBound(text string) (netip.Addr, error) {
	text = strings.TrimSpace(text)

	addr, err := netip.ParseAddr(text)
	if err != nil || addr.Zone() != "" {
		return netip.Addr{}, fmt.Errorf("%w: %q", errSweepRangeBound, text)
	}

	return addr.Unmap(), nil
}

// rangePrefixes returns the fewest prefixes that together hold exactly the
// addresses first through last. Both are the same family and first <= last.
func rangePrefixes(first, last netip.Addr) []netip.Prefix {
	var prefixes []netip.Prefix

	for {
		bits := first.BitLen()
		for bits > 0 {
			wider := netip.PrefixFrom(first, bits-1)
			if wider.Masked().Addr() != first || prefixLastAddr(wider).Compare(last) > 0 {
				break
			}

			bits--
		}

		prefix := netip.PrefixFrom(first, bits)
		prefixes = append(prefixes, prefix)

		end := prefixLastAddr(prefix)
		if end.Compare(last) >= 0 {
			return prefixes
		}

		first = end.Next()
	}
}

// prefixLastAddr returns the highest address in prefix.
func prefixLastAddr(prefix netip.Prefix) netip.Addr {
	octets := prefix.Masked().Addr().AsSlice()
	for i := range octets {
		switch hostBits := (i+1)*8 - prefix.Bits(); {
		case hostBits >= 8:
			octets[i] = 0xff
		case hostBits > 0:
			octets[i] |= byte(0xff >> (8 - hostBits))
		}
	}

	last, _ := netip.AddrFromSlice(octets)

	return last
}

// prefixesExceed reports whether prefixes hold more than limit addresses.
func prefixesExceed(prefixes []netip.Prefix, limit uint64) bool {
	var total uint64

	for _, prefix := range prefixes {
		hostBits := prefix.Addr().BitLen() - prefix.Bits()
		if hostBits >= 64 {
			return true
		}

		total += 1 << hostBits
		if total > limit {
			return true
		}
	}

	return false
}

// sweepNetworksForPrefixes writes a range's prefixes as sweeper CIDR entries.
// The sweeper skips the first and last address of an IPv4 CIDR other than /32
// as its network and broadcast address. A range lists every address it holds,
// so each multi-address IPv4 prefix also gets its two ends as /32 entries, and
// a /31, which the sweeper would expand to nothing, is written as two /32s.
func sweepNetworksForPrefixes(prefixes []netip.Prefix) []string {
	networks := make([]string, 0, len(prefixes))

	for _, prefix := range prefixes {
		if !prefix.Addr().Is4() || prefix.IsSingleIP() {
			networks = append(networks, prefix.String())
			continue
		}

		networks = append(networks, netip.PrefixFrom(prefix.Addr(), 32).String())
		if prefix.Bits() < 31 {
			networks = append(networks, prefix.String())
		}

		networks = append(networks, netip.PrefixFrom(prefixLastAddr(prefix), 32).String())
	}

	return networks
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

		networks, err := normalizeSweepNetwork(network)
		if err != nil {
			log.Warn().Err(err).Str("network", t.Network).Msg("Skipping invalid device target network")
			continue
		}

		sweepModes := parseSweepModes(t.SweepModes, log)
		for _, normalized := range networks {
			converted = append(converted, models.DeviceTarget{
				Network:    normalized,
				SweepModes: sweepModes,
				QueryLabel: t.QueryLabel,
				Source:     t.Source,
				Metadata:   t.Metadata,
			})
		}
	}

	return converted
}

// normalizeDeviceTargets normalizes device target networks the way
// convertDeviceTargets does, for device targets that did not arrive in a
// gateway payload. A range becomes one device target per CIDR entry.
func normalizeDeviceTargets(targets []models.DeviceTarget, log logger.Logger) []models.DeviceTarget {
	if len(targets) == 0 {
		return nil
	}

	normalized := make([]models.DeviceTarget, 0, len(targets))
	for _, target := range targets {
		network := strings.TrimSpace(target.Network)
		if network == "" {
			continue
		}

		networks, err := normalizeSweepNetwork(network)
		if err != nil {
			log.Warn().Err(err).Str("network", target.Network).Msg("Skipping invalid device target network")
			continue
		}

		for _, entry := range networks {
			target.Network = entry
			normalized = append(normalized, target)
		}
	}

	return normalized
}
