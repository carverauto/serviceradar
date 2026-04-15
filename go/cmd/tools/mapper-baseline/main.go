package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/mapper"
)

const (
	defaultWorkers      = 4
	defaultPollInterval = 500 * time.Millisecond

	modeSNMP       = "snmp"
	modeAPI        = "api"
	modeController = "controller"
	modeSNMPAPI    = "snmp_api"
)

var (
	errBaselineConfigRequired    = errors.New("baseline config is required")
	errBaselineModeRequired      = errors.New("baseline mode is required")
	errSNMPNeedsSeed             = errors.New("snmp baseline requires at least one seed")
	errControllerNeedsController = errors.New("controller baseline requires at least one controller")
	errUniFiNeedsController      = errors.New("unifi baseline requires at least one controller")
	errMikroTikNeedsController   = errors.New("mikrotik baseline requires at least one controller")
	errUnsupportedBaselineMode   = errors.New("unsupported baseline mode")
	errBaselineNeedsSeed         = errors.New("baseline requires at least one seed or derivable controller host")
	errUnsupportedDiscoveryType  = errors.New("unsupported discovery type")
	errDiscoveryEndedWithStatus  = errors.New("discovery ended")
)

type stringSliceFlag []string

func (f *stringSliceFlag) String() string {
	return strings.Join(*f, ",")
}

func (f *stringSliceFlag) Set(value string) error {
	for _, part := range strings.Split(value, ",") {
		trimmed := strings.TrimSpace(part)
		if trimmed == "" {
			continue
		}
		*f = append(*f, trimmed)
	}

	return nil
}

type runConfig struct {
	Mode          string                     `json:"mode"`
	Seeds         []string                   `json:"seeds,omitempty"`
	Type          string                     `json:"type,omitempty"`
	DiscoveryMode string                     `json:"discovery_mode,omitempty"`
	Concurrency   int                        `json:"concurrency,omitempty"`
	Timeout       string                     `json:"timeout,omitempty"`
	Retries       int                        `json:"retries,omitempty"`
	Output        string                     `json:"output,omitempty"`
	SNMP          snmpRunConfig              `json:"snmp,omitempty"`
	UniFi         []mapper.UniFiAPIConfig    `json:"unifi,omitempty"`
	MikroTik      []mapper.MikroTikAPIConfig `json:"mikrotik,omitempty"`
}

type snmpRunConfig struct {
	Version         string `json:"version,omitempty"`
	Community       string `json:"community,omitempty"`
	Username        string `json:"username,omitempty"`
	AuthProtocol    string `json:"auth_protocol,omitempty"`
	AuthPassword    string `json:"auth_password,omitempty"`
	PrivacyProtocol string `json:"privacy_protocol,omitempty"`
	PrivacyPassword string `json:"privacy_password,omitempty"`
}

type baselineReport struct {
	GeneratedAt   string                        `json:"generated_at"`
	DiscoveryID   string                        `json:"discovery_id"`
	Mode          string                        `json:"mode"`
	Type          string                        `json:"type"`
	DiscoveryMode string                        `json:"discovery_mode,omitempty"`
	Inputs        baselineReportInputs          `json:"inputs"`
	Status        *mapper.DiscoveryStatus       `json:"status"`
	Summary       baselineReportSummary         `json:"summary"`
	Devices       []*mapper.DiscoveredDevice    `json:"devices"`
	Interfaces    []*mapper.DiscoveredInterface `json:"interfaces"`
	TopologyLinks []*mapper.TopologyLink        `json:"topology_links"`
}

type baselineReportInputs struct {
	Seeds    []string `json:"seeds,omitempty"`
	UniFi    []string `json:"unifi,omitempty"`
	MikroTik []string `json:"mikrotik,omitempty"`
}

type baselineReportSummary struct {
	Devices          int          `json:"devices"`
	Interfaces       int          `json:"interfaces"`
	TopologyLinks    int          `json:"topology_links"`
	ByProtocol       []namedCount `json:"by_protocol"`
	ByEvidenceClass  []namedCount `json:"by_evidence_class"`
	ByConfidenceTier []namedCount `json:"by_confidence_tier"`
}

type namedCount struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
}

type nopPublisher struct{}

func (nopPublisher) PublishDevice(context.Context, *mapper.DiscoveredDevice) error       { return nil }
func (nopPublisher) PublishInterface(context.Context, *mapper.DiscoveredInterface) error { return nil }
func (nopPublisher) PublishTopologyLink(context.Context, *mapper.TopologyLink) error     { return nil }

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg, err := parseRunConfig(os.Args[1:])
	if err != nil {
		fatal(err)
	}

	if err := cfg.normalize(); err != nil {
		fatal(err)
	}

	mapperCfg, params, err := cfg.toMapperInputs()
	if err != nil {
		fatal(err)
	}

	engine, err := mapper.NewDiscoveryEngine(mapperCfg, nopPublisher{}, logger.NewTestLogger())
	if err != nil {
		fatal(err)
	}

	if err := engine.Start(ctx); err != nil {
		fatal(err)
	}

	defer func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = engine.Stop(stopCtx)
	}()

	discoveryID, err := engine.StartDiscovery(ctx, params)
	if err != nil {
		fatal(err)
	}

	results, err := waitForResults(ctx, engine, discoveryID)
	if err != nil {
		fatal(err)
	}

	report := buildReport(cfg, results)
	if err := writeReport(cfg.Output, report); err != nil {
		fatal(err)
	}
}

func parseRunConfig(args []string) (*runConfig, error) {
	fs := flag.NewFlagSet("mapper-baseline", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var cfg runConfig
	var configPath string
	var seeds stringSliceFlag

	var unifiBaseURL string
	var unifiAPIKey string
	var unifiName string
	var unifiInsecure bool

	var mikrotikBaseURL string
	var mikrotikUsername string
	var mikrotikPassword string
	var mikrotikName string
	var mikrotikInsecure bool

	fs.StringVar(&configPath, "config", "", "Path to a JSON baseline config file")
	fs.StringVar(&cfg.Mode, "mode", "", "Baseline mode: snmp, unifi, mikrotik, controller, api, or snmp_api")
	fs.Var(&seeds, "seed", "Seed target or controller-correlated host; repeat or provide comma-separated values")
	fs.StringVar(&cfg.Type, "type", string(mapper.DiscoveryTypeTopology), "Discovery type: full, basic, interfaces, or topology")
	fs.StringVar(&cfg.DiscoveryMode, "discovery-mode", "", "Optional mapper discovery mode override")
	fs.IntVar(&cfg.Concurrency, "concurrency", 0, "Maximum concurrent operations")
	fs.StringVar(&cfg.Timeout, "timeout", "", "Discovery timeout, for example 30s or 2m")
	fs.IntVar(&cfg.Retries, "retries", 0, "Retries per target")
	fs.StringVar(&cfg.Output, "output", "", "Optional output path for the JSON report; defaults to stdout")

	fs.StringVar(&cfg.SNMP.Version, "snmp-version", "", "SNMP version: v1, v2c, or v3")
	fs.StringVar(&cfg.SNMP.Community, "snmp-community", "", "SNMP community string")
	fs.StringVar(&cfg.SNMP.Username, "snmp-username", "", "SNMPv3 username")
	fs.StringVar(&cfg.SNMP.AuthProtocol, "snmp-auth-protocol", "", "SNMPv3 auth protocol")
	fs.StringVar(&cfg.SNMP.AuthPassword, "snmp-auth-password", "", "SNMPv3 auth password")
	fs.StringVar(&cfg.SNMP.PrivacyProtocol, "snmp-privacy-protocol", "", "SNMPv3 privacy protocol")
	fs.StringVar(&cfg.SNMP.PrivacyPassword, "snmp-privacy-password", "", "SNMPv3 privacy password")

	fs.StringVar(&unifiBaseURL, "unifi-base-url", "", "UniFi controller base URL")
	fs.StringVar(&unifiAPIKey, "unifi-api-key", "", "UniFi controller API key")
	fs.StringVar(&unifiName, "unifi-name", "", "Optional UniFi controller name")
	fs.BoolVar(&unifiInsecure, "unifi-insecure-skip-verify", false, "Skip TLS verification for UniFi")

	fs.StringVar(&mikrotikBaseURL, "mikrotik-base-url", "", "MikroTik REST base URL")
	fs.StringVar(&mikrotikUsername, "mikrotik-username", "", "MikroTik username")
	fs.StringVar(&mikrotikPassword, "mikrotik-password", "", "MikroTik password")
	fs.StringVar(&mikrotikName, "mikrotik-name", "", "Optional MikroTik endpoint name")
	fs.BoolVar(&mikrotikInsecure, "mikrotik-insecure-skip-verify", false, "Skip TLS verification for MikroTik")

	if err := fs.Parse(args); err != nil {
		return nil, err
	}

	flagCfg := cfg
	flagSeeds := append([]string(nil), seeds...)
	flagSet := make(map[string]bool)
	fs.Visit(func(f *flag.Flag) {
		flagSet[f.Name] = true
	})

	if configPath != "" {
		loaded, err := loadRunConfig(configPath)
		if err != nil {
			return nil, err
		}
		cfg = *loaded
	}

	if flagSet["mode"] {
		cfg.Mode = flagCfg.Mode
	}
	if flagSet["type"] {
		cfg.Type = flagCfg.Type
	}
	if flagSet["discovery-mode"] {
		cfg.DiscoveryMode = flagCfg.DiscoveryMode
	}
	if flagSet["concurrency"] {
		cfg.Concurrency = flagCfg.Concurrency
	}
	if flagSet["timeout"] {
		cfg.Timeout = flagCfg.Timeout
	}
	if flagSet["retries"] {
		cfg.Retries = flagCfg.Retries
	}
	if flagSet["output"] {
		cfg.Output = flagCfg.Output
	}
	if len(flagSeeds) > 0 {
		cfg.Seeds = flagSeeds
	}
	if flagSet["snmp-version"] {
		cfg.SNMP.Version = flagCfg.SNMP.Version
	}
	if flagSet["snmp-community"] {
		cfg.SNMP.Community = flagCfg.SNMP.Community
	}
	if flagSet["snmp-username"] {
		cfg.SNMP.Username = flagCfg.SNMP.Username
	}
	if flagSet["snmp-auth-protocol"] {
		cfg.SNMP.AuthProtocol = flagCfg.SNMP.AuthProtocol
	}
	if flagSet["snmp-auth-password"] {
		cfg.SNMP.AuthPassword = flagCfg.SNMP.AuthPassword
	}
	if flagSet["snmp-privacy-protocol"] {
		cfg.SNMP.PrivacyProtocol = flagCfg.SNMP.PrivacyProtocol
	}
	if flagSet["snmp-privacy-password"] {
		cfg.SNMP.PrivacyPassword = flagCfg.SNMP.PrivacyPassword
	}

	if flagSet["unifi-base-url"] || flagSet["unifi-api-key"] || flagSet["unifi-name"] || flagSet["unifi-insecure-skip-verify"] {
		cfg.UniFi = []mapper.UniFiAPIConfig{{
			BaseURL:            strings.TrimSpace(unifiBaseURL),
			APIKey:             strings.TrimSpace(unifiAPIKey),
			Name:               strings.TrimSpace(unifiName),
			InsecureSkipVerify: unifiInsecure,
		}}
	}

	if flagSet["mikrotik-base-url"] || flagSet["mikrotik-username"] || flagSet["mikrotik-password"] || flagSet["mikrotik-name"] || flagSet["mikrotik-insecure-skip-verify"] {
		cfg.MikroTik = []mapper.MikroTikAPIConfig{{
			BaseURL:            strings.TrimSpace(mikrotikBaseURL),
			Username:           strings.TrimSpace(mikrotikUsername),
			Password:           strings.TrimSpace(mikrotikPassword),
			Name:               strings.TrimSpace(mikrotikName),
			InsecureSkipVerify: mikrotikInsecure,
		}}
	}

	return &cfg, nil
}

func loadRunConfig(path string) (*runConfig, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}

	var cfg runConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	return &cfg, nil
}

func (c *runConfig) normalize() error {
	if c == nil {
		return errBaselineConfigRequired
	}

	c.Mode = strings.ToLower(strings.TrimSpace(c.Mode))
	if c.Mode == "" {
		return errBaselineModeRequired
	}
	c.DiscoveryMode = normalizeDiscoveryMode(c.DiscoveryMode)

	if c.Type == "" {
		c.Type = string(mapper.DiscoveryTypeTopology)
	}

	for i := range c.Seeds {
		c.Seeds[i] = strings.TrimSpace(c.Seeds[i])
	}
	c.Seeds = uniqueNonEmpty(c.Seeds)

	for i := range c.UniFi {
		c.UniFi[i].BaseURL = strings.TrimSpace(c.UniFi[i].BaseURL)
		c.UniFi[i].APIKey = strings.TrimSpace(c.UniFi[i].APIKey)
		c.UniFi[i].Name = strings.TrimSpace(c.UniFi[i].Name)
	}
	for i := range c.MikroTik {
		c.MikroTik[i].BaseURL = strings.TrimSpace(c.MikroTik[i].BaseURL)
		c.MikroTik[i].Username = strings.TrimSpace(c.MikroTik[i].Username)
		c.MikroTik[i].Password = strings.TrimSpace(c.MikroTik[i].Password)
		c.MikroTik[i].Name = strings.TrimSpace(c.MikroTik[i].Name)
	}

	switch c.Mode {
	case modeAPI:
		c.Mode = modeController
		c.DiscoveryMode = modeAPI
	case modeSNMPAPI:
		c.Mode = modeController
		c.DiscoveryMode = modeSNMPAPI
	}

	switch c.Mode {
	case modeSNMP:
		if len(c.Seeds) == 0 {
			return errSNMPNeedsSeed
		}
		if c.SNMP.Version == "" {
			c.SNMP.Version = string(mapper.SNMPVersion2c)
		}
		if c.DiscoveryMode == "" {
			c.DiscoveryMode = modeSNMP
		}
	case modeController:
		if len(c.UniFi) == 0 && len(c.MikroTik) == 0 {
			return errControllerNeedsController
		}
		if len(c.Seeds) == 0 {
			c.Seeds = deriveControllerSeeds(c.UniFi, c.MikroTik)
		}
		if c.DiscoveryMode == "" {
			c.DiscoveryMode = modeAPI
		}
	case "unifi":
		if len(c.UniFi) == 0 {
			return errUniFiNeedsController
		}
		if len(c.Seeds) == 0 {
			c.Seeds = deriveUniFiSeeds(c.UniFi)
		}
		if c.DiscoveryMode == "" {
			c.DiscoveryMode = modeAPI
		}
	case "mikrotik":
		if len(c.MikroTik) == 0 {
			return errMikroTikNeedsController
		}
		if len(c.Seeds) == 0 {
			c.Seeds = deriveMikroTikSeeds(c.MikroTik)
		}
		if c.DiscoveryMode == "" {
			c.DiscoveryMode = modeAPI
		}
	default:
		return fmt.Errorf("%w: %q", errUnsupportedBaselineMode, c.Mode)
	}

	if len(c.Seeds) == 0 {
		return fmt.Errorf("%s %w", c.Mode, errBaselineNeedsSeed)
	}

	if _, err := parseDiscoveryType(c.Type); err != nil {
		return err
	}

	if c.Timeout != "" {
		if _, err := time.ParseDuration(c.Timeout); err != nil {
			return fmt.Errorf("invalid timeout %q: %w", c.Timeout, err)
		}
	}

	return nil
}

func (c *runConfig) toMapperInputs() (*mapper.Config, *mapper.DiscoveryParams, error) {
	discoveryType, err := parseDiscoveryType(c.Type)
	if err != nil {
		return nil, nil, err
	}

	timeout := 30 * time.Second
	if c.Timeout != "" {
		timeout, err = time.ParseDuration(c.Timeout)
		if err != nil {
			return nil, nil, fmt.Errorf("invalid timeout: %w", err)
		}
	}

	workers := c.Concurrency
	if workers <= 0 {
		workers = defaultWorkers
	}

	snmpVersion := strings.ToLower(strings.TrimSpace(c.SNMP.Version))
	if snmpVersion == "" {
		snmpVersion = string(mapper.SNMPVersion2c)
	}

	cfg := &mapper.Config{
		Workers:         workers,
		Timeout:         timeout,
		Retries:         c.Retries,
		MaxActiveJobs:   1,
		ResultRetention: time.Hour,
		DefaultCredentials: mapper.SNMPCredentials{
			Version:         mapper.SNMPVersion(snmpVersion),
			Community:       c.SNMP.Community,
			Username:        c.SNMP.Username,
			AuthProtocol:    c.SNMP.AuthProtocol,
			AuthPassword:    c.SNMP.AuthPassword,
			PrivacyProtocol: c.SNMP.PrivacyProtocol,
			PrivacyPassword: c.SNMP.PrivacyPassword,
		},
		UniFiAPIs:    append([]mapper.UniFiAPIConfig(nil), c.UniFi...),
		MikroTikAPIs: append([]mapper.MikroTikAPIConfig(nil), c.MikroTik...),
	}

	params := &mapper.DiscoveryParams{
		Seeds:       append([]string(nil), c.Seeds...),
		Type:        discoveryType,
		Mode:        strings.TrimSpace(c.DiscoveryMode),
		Credentials: &cfg.DefaultCredentials,
		Options:     map[string]string{"baseline_mode": c.Mode},
		Concurrency: c.Concurrency,
		Timeout:     timeout,
		Retries:     c.Retries,
		AgentID:     "mapper-baseline",
		GatewayID:   "mapper-baseline",
	}

	return cfg, params, nil
}

func parseDiscoveryType(value string) (mapper.DiscoveryType, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "full":
		return mapper.DiscoveryTypeFull, nil
	case "basic":
		return mapper.DiscoveryTypeBasic, nil
	case "interfaces":
		return mapper.DiscoveryTypeInterfaces, nil
	case "", "topology":
		return mapper.DiscoveryTypeTopology, nil
	default:
		return "", fmt.Errorf("%w: %q", errUnsupportedDiscoveryType, value)
	}
}

func waitForResults(ctx context.Context, engine mapper.Mapper, discoveryID string) (*mapper.DiscoveryResults, error) {
	ticker := time.NewTicker(defaultPollInterval)
	defer ticker.Stop()

	for {
		status, err := engine.GetDiscoveryStatus(ctx, discoveryID)
		if err != nil {
			return nil, err
		}

		switch status.Status {
		case mapper.DiscoveryStatusCompleted:
			return engine.GetDiscoveryResults(ctx, discoveryID, true)
		case mapper.DiscoveryStatusFailed, mapper.DiscoverStatusCanceled:
			results, resultsErr := engine.GetDiscoveryResults(ctx, discoveryID, true)
			endedErr := fmt.Errorf("%w: %s with status %s: %s", errDiscoveryEndedWithStatus, discoveryID, status.Status, status.Error)
			if resultsErr == nil {
				return results, endedErr
			}
			return nil, endedErr
		case mapper.DiscoveryStatusUnknown, mapper.DiscoveryStatusPending, mapper.DiscoveryStatusRunning:
			// non-terminal states keep polling
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}

func buildReport(cfg *runConfig, results *mapper.DiscoveryResults) *baselineReport {
	devices := append([]*mapper.DiscoveredDevice(nil), results.Devices...)
	interfaces := append([]*mapper.DiscoveredInterface(nil), results.Interfaces...)
	links := append([]*mapper.TopologyLink(nil), results.TopologyLinks...)

	sort.Slice(devices, func(i, j int) bool { return compareDevices(devices[i], devices[j]) < 0 })
	sort.Slice(interfaces, func(i, j int) bool { return compareInterfaces(interfaces[i], interfaces[j]) < 0 })
	sort.Slice(links, func(i, j int) bool { return compareLinks(links[i], links[j]) < 0 })

	return &baselineReport{
		GeneratedAt:   time.Now().UTC().Format(time.RFC3339Nano),
		DiscoveryID:   results.DiscoveryID,
		Mode:          cfg.Mode,
		Type:          cfg.Type,
		DiscoveryMode: cfg.DiscoveryMode,
		Inputs: baselineReportInputs{
			Seeds:    append([]string(nil), cfg.Seeds...),
			UniFi:    uniFiBaseURLs(cfg.UniFi),
			MikroTik: mikroTikBaseURLs(cfg.MikroTik),
		},
		Status: results.Status,
		Summary: baselineReportSummary{
			Devices:          len(devices),
			Interfaces:       len(interfaces),
			TopologyLinks:    len(links),
			ByProtocol:       countTopologyLinks(links, func(link *mapper.TopologyLink) string { return normalizeCountKey(link.Protocol) }),
			ByEvidenceClass:  countTopologyLinks(links, func(link *mapper.TopologyLink) string { return normalizeCountKey(link.Metadata["evidence_class"]) }),
			ByConfidenceTier: countTopologyLinks(links, func(link *mapper.TopologyLink) string { return normalizeCountKey(link.Metadata["confidence_tier"]) }),
		},
		Devices:       devices,
		Interfaces:    interfaces,
		TopologyLinks: links,
	}
}

func countTopologyLinks(links []*mapper.TopologyLink, fn func(*mapper.TopologyLink) string) []namedCount {
	counts := make(map[string]int)
	for _, link := range links {
		counts[fn(link)]++
	}

	return mapToNamedCounts(counts)
}

func mapToNamedCounts(values map[string]int) []namedCount {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	out := make([]namedCount, 0, len(keys))
	for _, key := range keys {
		out = append(out, namedCount{Name: key, Count: values[key]})
	}

	return out
}

func normalizeCountKey(value string) string {
	trimmed := strings.TrimSpace(strings.ToLower(value))
	if trimmed == "" {
		return "unknown"
	}

	return trimmed
}

func writeReport(path string, report *baselineReport) error {
	raw, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal report: %w", err)
	}

	if strings.TrimSpace(path) == "" {
		_, err = os.Stdout.Write(append(raw, '\n'))
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}

	if err := os.WriteFile(path, append(raw, '\n'), 0o644); err != nil {
		return fmt.Errorf("write report: %w", err)
	}

	return nil
}

func deriveUniFiSeeds(controllers []mapper.UniFiAPIConfig) []string {
	baseURLs := make([]string, 0, len(controllers))
	for _, controller := range controllers {
		baseURLs = append(baseURLs, controller.BaseURL)
	}

	return deriveSeedsFromBaseURLs(baseURLs)
}

func deriveMikroTikSeeds(controllers []mapper.MikroTikAPIConfig) []string {
	baseURLs := make([]string, 0, len(controllers))
	for _, controller := range controllers {
		baseURLs = append(baseURLs, controller.BaseURL)
	}

	return deriveSeedsFromBaseURLs(baseURLs)
}

func deriveControllerSeeds(unifi []mapper.UniFiAPIConfig, mikrotik []mapper.MikroTikAPIConfig) []string {
	seeds := append(deriveUniFiSeeds(unifi), deriveMikroTikSeeds(mikrotik)...)
	return uniqueNonEmpty(seeds)
}

func normalizeDiscoveryMode(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "default":
		return ""
	case "api", "api_only", "api-only":
		return "api"
	case "snmp", "snmp_only", "snmp-only":
		return "snmp"
	case "snmp_api", "snmp-api":
		return "snmp_api"
	default:
		return strings.ToLower(strings.TrimSpace(value))
	}
}

func deriveSeedsFromBaseURLs(baseURLs []string) []string {
	seeds := make([]string, 0, len(baseURLs))
	for _, rawURL := range baseURLs {
		parsed, err := url.Parse(strings.TrimSpace(rawURL))
		if err != nil {
			continue
		}
		if host := strings.TrimSpace(parsed.Hostname()); host != "" {
			seeds = append(seeds, host)
		}
	}

	return uniqueNonEmpty(seeds)
}

func uniFiBaseURLs(controllers []mapper.UniFiAPIConfig) []string {
	values := make([]string, 0, len(controllers))
	for _, controller := range controllers {
		values = append(values, strings.TrimSpace(controller.BaseURL))
	}

	return uniqueNonEmpty(values)
}

func mikroTikBaseURLs(controllers []mapper.MikroTikAPIConfig) []string {
	values := make([]string, 0, len(controllers))
	for _, controller := range controllers {
		values = append(values, strings.TrimSpace(controller.BaseURL))
	}

	return uniqueNonEmpty(values)
}

func uniqueNonEmpty(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			continue
		}
		if _, ok := seen[trimmed]; ok {
			continue
		}
		seen[trimmed] = struct{}{}
		out = append(out, trimmed)
	}
	sort.Strings(out)
	return out
}

func compareDevices(left, right *mapper.DiscoveredDevice) int {
	return compareTuple(
		nonnullDevice(left).DeviceID, nonnullDevice(right).DeviceID,
		nonnullDevice(left).IP, nonnullDevice(right).IP,
		nonnullDevice(left).MAC, nonnullDevice(right).MAC,
	)
}

func compareInterfaces(left, right *mapper.DiscoveredInterface) int {
	return compareTuple(
		nonnullInterface(left).DeviceID, nonnullInterface(right).DeviceID,
		fmt.Sprintf("%09d", nonnullInterface(left).IfIndex), fmt.Sprintf("%09d", nonnullInterface(right).IfIndex),
		nonnullInterface(left).IfName, nonnullInterface(right).IfName,
	)
}

func compareLinks(left, right *mapper.TopologyLink) int {
	return compareTuple(
		nonnullLink(left).LocalDeviceID, nonnullLink(right).LocalDeviceID,
		nonnullLink(left).LocalDeviceIP, nonnullLink(right).LocalDeviceIP,
		fmt.Sprintf("%09d", nonnullLink(left).LocalIfIndex), fmt.Sprintf("%09d", nonnullLink(right).LocalIfIndex),
		normalizeCountKey(nonnullLink(left).Protocol), normalizeCountKey(nonnullLink(right).Protocol),
		nonnullLink(left).NeighborMgmtAddr, nonnullLink(right).NeighborMgmtAddr,
		nonnullLink(left).NeighborSystemName, nonnullLink(right).NeighborSystemName,
	)
}

func compareTuple(values ...string) int {
	for i := 0; i < len(values); i += 2 {
		if values[i] < values[i+1] {
			return -1
		}
		if values[i] > values[i+1] {
			return 1
		}
	}
	return 0
}

func nonnullDevice(device *mapper.DiscoveredDevice) *mapper.DiscoveredDevice {
	if device == nil {
		return &mapper.DiscoveredDevice{}
	}
	return device
}

func nonnullInterface(iface *mapper.DiscoveredInterface) *mapper.DiscoveredInterface {
	if iface == nil {
		return &mapper.DiscoveredInterface{}
	}
	return iface
}

func nonnullLink(link *mapper.TopologyLink) *mapper.TopologyLink {
	if link == nil {
		return &mapper.TopologyLink{}
	}
	return link
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "mapper-baseline: %v\n", err)
	os.Exit(1)
}
