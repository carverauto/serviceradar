package agent

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultArmisPageSize    = 100
	defaultSyncRunTimeout   = 10 * time.Minute
	syncServiceType         = "sync"
	syncServiceName         = "sync"
	syncMetaKey             = "sync_meta"
	armisSourceType         = "armis"
	armisAccessTokenPath    = "/api/v1/access_token/"
	armisSearchPath         = "/api/v1/search/"
	armisAuthHeaderTemplate = "Bearer %s"
)

var (
	errSyncRuntimeNoContext         = errors.New("sync runtime requires context")
	errUnsupportedSyncSourceType    = errors.New("unsupported sync source type")
	errArmisTokenRequestFailed      = errors.New("armis token request failed")
	errArmisTokenMissingAccessToken = errors.New("armis token response missing access_token")
	errArmisSearchFailed            = errors.New("armis search failed")
)

// SyncRuntime executes integration sources delivered via GetConfig.
type SyncRuntime struct {
	server  *Server
	gateway *agentgateway.GatewayClient
	logger  logger.Logger

	mu      sync.Mutex
	ctx     context.Context
	sources map[string]*syncSourceRunner
}

type syncSourceRunner struct {
	key    string
	hash   string
	config models.SourceConfig
	cancel context.CancelFunc

	mu       sync.Mutex
	inflight bool
}

type syncConfigPayload struct {
	AgentID string                         `json:"agent_id"`
	Sources map[string]models.SourceConfig `json:"sources"`
}

type armisDevice struct {
	ID                int                      `json:"id"`
	DeviceID          int                      `json:"device_id"`
	IPAddress         string                   `json:"ipAddress"`
	IPv4Addresses     []string                 `json:"ipv4_addresses"`
	IPv6Addresses     []string                 `json:"ipv6_addresses"`
	MacAddress        string                   `json:"macAddress"`
	MacAddresses      []string                 `json:"mac_addresses"`
	Name              string                   `json:"name"`
	Names             []string                 `json:"names"`
	Display           string                   `json:"display"`
	Type              string                   `json:"type"`
	Category          string                   `json:"category"`
	Manufacturer      string                   `json:"manufacturer"`
	Brand             string                   `json:"brand"`
	Model             string                   `json:"model"`
	OperatingSystem   string                   `json:"operatingSystem"`
	OSName            string                   `json:"os_name"`
	OSVersion         string                   `json:"os_version"`
	FirstSeen         time.Time                `json:"firstSeen"`
	FirstSeenSnake    time.Time                `json:"first_seen"`
	LastSeen          time.Time                `json:"lastSeen"`
	LastSeenSnake     time.Time                `json:"last_seen"`
	RiskLevel         int                      `json:"riskLevel"`
	RiskLevelSnake    int                      `json:"risk_level"`
	Boundaries        interface{}              `json:"boundaries"`
	Tags              []string                 `json:"tags"`
	NetworkInterfaces []map[string]interface{} `json:"network_interfaces"`
	PurdueLevel       *float64                 `json:"purdue_level"`
	SerialNumbers     []string                 `json:"serial_numbers"`
	Site              map[string]interface{}   `json:"site"`
	Visibility        string                   `json:"visibility"`
}

type armisSearchResponse struct {
	Data struct {
		Count   int           `json:"count"`
		Next    int           `json:"next"`
		Prev    interface{}   `json:"prev"`
		Results []armisDevice `json:"results"`
		Total   int           `json:"total"`
	} `json:"data"`
	Success bool `json:"success"`
}

type armisTokenResponse struct {
	Data struct {
		AccessToken string `json:"access_token"`
	} `json:"data"`
	Success bool `json:"success"`
}

// NewSyncRuntime builds the integration sync runtime for an agent.
func NewSyncRuntime(server *Server, gateway *agentgateway.GatewayClient, log logger.Logger) *SyncRuntime {
	return &SyncRuntime{
		server:  server,
		gateway: gateway,
		logger:  log,
		sources: make(map[string]*syncSourceRunner),
	}
}

// SetContext sets the base context for sync runners (called from PushLoop.Start).
func (r *SyncRuntime) SetContext(ctx context.Context) {
	r.mu.Lock()
	r.ctx = ctx
	r.mu.Unlock()
}

// ApplyConfig parses sync sources from the gateway payload and starts/stops runners.
func (r *SyncRuntime) ApplyConfig(configJSON []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.ctx == nil {
		r.logger.Warn().Err(errSyncRuntimeNoContext).Msg("Skipping sync runtime config")
		return
	}

	if !syncRuntimeEnabled(r.server.config) {
		r.stopAllLocked()
		return
	}

	sources, err := parseSyncSources(configJSON)
	if err != nil {
		r.logger.Warn().Err(err).Msg("Failed to parse sync sources from config")
		return
	}

	if len(sources) == 0 {
		r.stopAllLocked()
		return
	}

	// Stop removed sources.
	for key, runner := range r.sources {
		if _, ok := sources[key]; !ok {
			runner.cancel()
			delete(r.sources, key)
		}
	}

	for key, source := range sources {
		if !isSupportedSource(source.Type) {
			r.logger.Warn().Str("source", key).Str("type", source.Type).
				Msg("Skipping unsupported sync source type")
			continue
		}

		if strings.TrimSpace(source.Endpoint) == "" {
			r.logger.Warn().Str("source", key).Msg("Skipping sync source without endpoint")
			continue
		}

		hash := syncSourceHash(source)
		if existing, ok := r.sources[key]; ok {
			if existing.hash == hash {
				continue
			}
			existing.cancel()
			delete(r.sources, key)
		}

		r.sources[key] = r.startSourceLocked(key, source, hash)
	}
}

func (r *SyncRuntime) stopAllLocked() {
	for key, runner := range r.sources {
		runner.cancel()
		delete(r.sources, key)
	}
}

func (r *SyncRuntime) startSourceLocked(key string, source models.SourceConfig, hash string) *syncSourceRunner {
	ctx, cancel := context.WithCancel(r.ctx)
	runner := &syncSourceRunner{
		key:    key,
		hash:   hash,
		config: source,
		cancel: cancel,
	}

	go r.runSource(ctx, runner)
	return runner
}

func (r *SyncRuntime) runSource(ctx context.Context, runner *syncSourceRunner) {
	pollInterval := time.Duration(runner.config.PollInterval)
	discoveryInterval := time.Duration(runner.config.DiscoveryInterval)

	if pollInterval <= 0 && discoveryInterval <= 0 {
		r.logger.Warn().Str("source", runner.key).Msg("Sync source has no intervals configured")
		return
	}

	// Run an initial discovery immediately.
	r.executeRun(ctx, runner, "discovery")

	if discoveryInterval > 0 {
		ticker := time.NewTicker(discoveryInterval)
		defer ticker.Stop()

		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					r.executeRun(ctx, runner, "discovery")
				}
			}
		}()
	}

	if pollInterval > 0 && pollInterval != discoveryInterval {
		ticker := time.NewTicker(pollInterval)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				r.executeRun(ctx, runner, "poll")
			}
		}
	}

	<-ctx.Done()
}

func (r *SyncRuntime) executeRun(ctx context.Context, runner *syncSourceRunner, runKind string) {
	if !runner.tryStart() {
		r.logger.Debug().Str("source", runner.key).Msg("Sync run skipped (in progress)")
		return
	}
	defer runner.finish()

	runID := uuid.NewString()
	runCtx, cancel := context.WithTimeout(ctx, defaultSyncRunTimeout)
	defer cancel()

	start := time.Now()
	count, err := r.runSourceOnce(runCtx, runner, runKind, runID)
	duration := time.Since(start)

	logEvent := r.logger.Info()
	if err != nil {
		logEvent = r.logger.Error().Err(err)
	}

	logEvent.Str("source", runner.key).
		Str("type", runner.config.Type).
		Str("run_id", runID).
		Str("kind", runKind).
		Int("device_count", count).
		Dur("duration", duration).
		Msg("Sync run completed")
}

func (r *SyncRuntime) runSourceOnce(
	ctx context.Context,
	runner *syncSourceRunner,
	_ string,
	runID string,
) (int, error) {
	sourceType := strings.ToLower(strings.TrimSpace(runner.config.Type))
	switch sourceType {
	case armisSourceType:
		return r.runArmisSync(ctx, runner, runID)
	default:
		return 0, fmt.Errorf("%w: %s", errUnsupportedSyncSourceType, sourceType)
	}
}

func (r *SyncRuntime) runArmisSync(
	ctx context.Context,
	runner *syncSourceRunner,
	runID string,
) (int, error) {
	client := newArmisClient(runner.config)
	queries := runner.config.Queries
	if len(queries) == 0 {
		queries = []models.QueryConfig{{}}
	}

	token, err := client.accessToken(ctx, runner.config.Credentials)
	if err != nil {
		return 0, err
	}

	pageSize := armisPageSize(runner.config)
	updates := make([]map[string]interface{}, 0, pageSize*len(queries))

	for _, query := range queries {
		queryString := query.Query
		queryLabel := query.Label

		from := 0
		for {
			resp, err := client.search(ctx, token, queryString, from, pageSize)
			if err != nil {
				return len(updates), err
			}

			filtered := filterArmisDevices(resp.Data.Results, runner.config.NetworkBlacklist)
			r.logArmisShape(runID, queryLabel, from, filtered)

			for _, device := range filtered {
				update := buildArmisUpdate(r.server, runner, device, queryLabel)
				if update == nil {
					continue
				}
				updates = append(updates, update)
			}

			if resp.Data.Next <= 0 || resp.Data.Next <= from {
				break
			}

			from = resp.Data.Next
		}
	}

	if len(updates) == 0 {
		return 0, nil
	}

	if err := r.sendSyncUpdates(ctx, runner, updates, runID); err != nil {
		return len(updates), err
	}

	return len(updates), nil
}

func (r *SyncRuntime) logArmisShape(runID, queryLabel string, from int, devices []armisDevice) {
	interfaceDeviceCount := 0
	var sampleInterfaceKeys []string

	for _, device := range devices {
		if len(device.NetworkInterfaces) == 0 {
			continue
		}

		interfaceDeviceCount++
		if len(sampleInterfaceKeys) == 0 {
			sampleInterfaceKeys = sortedMapKeys(device.NetworkInterfaces[0])
		}
	}

	boundaryDeviceCount := 0
	var sampleBoundaryNames []string
	for _, device := range devices {
		names := boundaryNames(device.Boundaries)
		if len(names) == 0 {
			continue
		}

		boundaryDeviceCount++
		if len(sampleBoundaryNames) == 0 {
			sampleBoundaryNames = names
		}
	}

	if interfaceDeviceCount == 0 && boundaryDeviceCount == 0 {
		return
	}

	r.logger.Info().
		Str("source", armisSourceType).
		Str("run_id", runID).
		Str("query_label", queryLabel).
		Int("from", from).
		Int("device_count", len(devices)).
		Int("devices_with_network_interfaces", interfaceDeviceCount).
		Strs("network_interface_sample_keys", sampleInterfaceKeys).
		Int("devices_with_boundaries", boundaryDeviceCount).
		Strs("boundary_sample_names", sampleBoundaryNames).
		Msg("Armis device shape sample")
}

func (r *SyncRuntime) sendSyncUpdates(
	ctx context.Context,
	runner *syncSourceRunner,
	updates []map[string]interface{},
	runID string,
) error {
	chunks, err := buildSyncResultsChunks(updates, runner.config, runID)
	if err != nil {
		return err
	}
	if len(chunks) == 0 {
		return nil
	}

	statusChunks := r.buildResultsStatusChunks(chunks, syncServiceName, syncServiceType)
	if len(statusChunks) == 0 {
		return nil
	}

	_, err = r.gateway.StreamStatus(ctx, statusChunks)
	return err
}

func (r *SyncRuntime) buildResultsStatusChunks(
	chunks []*proto.ResultsChunk,
	serviceName string,
	serviceType string,
) []*proto.GatewayStatusChunk {
	r.server.mu.RLock()
	agentID := r.server.config.AgentID
	partition := r.server.config.Partition
	r.server.mu.RUnlock()
	gatewayID := r.gateway.GetGatewayID()
	return buildResultsStatusChunksForAgent(chunks, serviceName, serviceType, agentID, partition, gatewayID)
}

func (r *syncSourceRunner) tryStart() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.inflight {
		return false
	}
	r.inflight = true
	return true
}

func (r *syncSourceRunner) finish() {
	r.mu.Lock()
	r.inflight = false
	r.mu.Unlock()
}

func syncRuntimeEnabled(cfg *ServerConfig) bool {
	if cfg == nil {
		return false
	}
	if cfg.SyncRuntimeEnabled == nil {
		return true
	}
	return *cfg.SyncRuntimeEnabled
}

func parseSyncSources(configJSON []byte) (map[string]models.SourceConfig, error) {
	if len(configJSON) == 0 {
		return nil, nil
	}

	var payload syncConfigPayload
	if err := json.Unmarshal(configJSON, &payload); err != nil {
		return nil, fmt.Errorf("decode sync payload: %w", err)
	}

	if len(payload.Sources) == 0 {
		return nil, nil
	}

	return payload.Sources, nil
}

func syncSourceHash(source models.SourceConfig) string {
	data, err := json.Marshal(source)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:8])
}

func isSupportedSource(sourceType string) bool {
	switch strings.ToLower(strings.TrimSpace(sourceType)) {
	case armisSourceType:
		return true
	default:
		return false
	}
}

func armisPageSize(source models.SourceConfig) int {
	value := source.Credentials["page_size"]
	if value == "" {
		return defaultArmisPageSize
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed <= 0 {
		return defaultArmisPageSize
	}
	return parsed
}

type armisClient struct {
	endpoint           string
	insecureSkipVerify bool
}

func newArmisClient(source models.SourceConfig) *armisClient {
	return &armisClient{
		endpoint:           strings.TrimRight(source.Endpoint, "/"),
		insecureSkipVerify: source.InsecureSkipVerify,
	}
}

func (c *armisClient) accessToken(ctx context.Context, creds map[string]string) (string, error) {
	url, err := c.resolveURL(armisAccessTokenPath)
	if err != nil {
		return "", err
	}

	payload := map[string]string{}
	if creds != nil {
		if value := firstCredentialValue(creds, "api_key", "key"); value != "" {
			payload["api_key"] = value
		}
		if value := firstCredentialValue(creds, "secret_key", "api_secret", "secret"); value != "" {
			payload["secret_key"] = value
		}
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(string(body)))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client().Do(req)
	if err != nil {
		return "", err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("%w: %s", errArmisTokenRequestFailed, resp.Status)
	}

	var token armisTokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&token); err != nil {
		return "", err
	}
	if token.Data.AccessToken == "" {
		return "", errArmisTokenMissingAccessToken
	}
	return token.Data.AccessToken, nil
}

func firstCredentialValue(creds map[string]string, keys ...string) string {
	for _, key := range keys {
		if value := strings.TrimSpace(creds[key]); value != "" {
			return value
		}
	}

	return ""
}

func (c *armisClient) search(ctx context.Context, token string, query string, from int, length int) (*armisSearchResponse, error) {
	endpoint, err := c.resolveURL(armisSearchPath)
	if err != nil {
		return nil, err
	}

	parsed, err := url.Parse(endpoint)
	if err != nil {
		return nil, err
	}

	params := parsed.Query()
	params.Set("from", strconv.Itoa(from))
	params.Set("length", strconv.Itoa(length))
	if query != "" {
		params.Set("aql", query)
	}
	parsed.RawQuery = params.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return nil, err
	}
	if token != "" {
		req.Header.Set("Authorization", fmt.Sprintf(armisAuthHeaderTemplate, token))
	}

	resp, err := c.client().Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%w: %s", errArmisSearchFailed, resp.Status)
	}

	var result armisSearchResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	return &result, nil
}

func (c *armisClient) resolveURL(path string) (string, error) {
	base, err := url.Parse(c.endpoint)
	if err != nil {
		return "", err
	}

	ref, err := url.Parse(path)
	if err != nil {
		return "", err
	}

	return base.ResolveReference(ref).String(), nil
}

func (c *armisClient) client() *http.Client {
	transport := http.DefaultTransport
	if c.insecureSkipVerify {
		transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		}
	}
	return &http.Client{Transport: transport}
}

func filterArmisDevices(devices []armisDevice, blacklist []string) []armisDevice {
	if len(blacklist) == 0 {
		return devices
	}

	cidrs := make([]*net.IPNet, 0, len(blacklist))
	for _, raw := range blacklist {
		_, network, err := net.ParseCIDR(strings.TrimSpace(raw))
		if err != nil {
			continue
		}
		cidrs = append(cidrs, network)
	}

	if len(cidrs) == 0 {
		return devices
	}

	filtered := make([]armisDevice, 0, len(devices))
	for _, device := range devices {
		ip := net.ParseIP(device.primaryIP())
		if ip == nil {
			filtered = append(filtered, device)
			continue
		}

		blocked := false
		for _, network := range cidrs {
			if network.Contains(ip) {
				blocked = true
				break
			}
		}

		if !blocked {
			filtered = append(filtered, device)
		}
	}

	return filtered
}

func buildArmisUpdate(server *Server, runner *syncSourceRunner, device armisDevice, queryLabel string) map[string]interface{} {
	ipAddress := device.primaryIP()
	if ipAddress == "" {
		return nil
	}

	context := armisUpdateContextFor(server, runner)
	metadata := buildArmisMetadata(device, queryLabel)
	update := map[string]interface{}{
		"agent_id":   context.agentID,
		"gateway_id": context.gatewayID,
		"partition":  context.partition,
		"device_id":  fmt.Sprintf("%s:%s", context.partition, ipAddress),
		"ip":         ipAddress,
		"source":     armisSourceType,
		"timestamp":  time.Now().UTC().Format(time.RFC3339Nano),
		"metadata":   metadata,
	}

	addArmisTopLevelFields(update, device)

	return update
}

type armisUpdateContext struct {
	agentID   string
	gatewayID string
	partition string
}

func armisUpdateContextFor(server *Server, runner *syncSourceRunner) armisUpdateContext {
	server.mu.RLock()
	agentID := server.config.AgentID
	partition := server.config.Partition
	server.mu.RUnlock()
	if runner.config.AgentID != "" {
		agentID = runner.config.AgentID
	}
	gatewayID := agentID
	if runner.config.GatewayID != "" {
		gatewayID = runner.config.GatewayID
	}
	if runner.config.Partition != "" {
		partition = runner.config.Partition
	}
	if partition == "" {
		partition = defaultPartition
	}

	return armisUpdateContext{
		agentID:   agentID,
		gatewayID: gatewayID,
		partition: partition,
	}
}

func buildArmisMetadata(device armisDevice, queryLabel string) map[string]string {
	metadata := map[string]string{
		"integration_type": armisSourceType,
	}
	if id := device.effectiveID(); id > 0 {
		deviceID := strconv.Itoa(id)
		metadata["source_device_id"] = deviceID
		metadata["integration_id"] = deviceID
	}

	if device.Type != "" {
		metadata["type"] = device.Type
		metadata["device_type"] = device.Type
	}
	if device.Category != "" {
		metadata["category"] = device.Category
	}
	if brand := firstNonEmpty(device.Brand, device.Manufacturer); brand != "" {
		metadata["brand"] = brand
		metadata["manufacturer"] = brand
	}
	if device.Model != "" {
		metadata["model"] = device.Model
	}
	if osName := firstNonEmpty(device.OSName, device.OperatingSystem); osName != "" {
		metadata["os_name"] = osName
		metadata["operating_system"] = osName
	}
	if device.OSVersion != "" {
		metadata["os_version"] = device.OSVersion
	}
	if encoded := compactJSONValue(device.Boundaries); encoded != "" {
		metadata["boundaries"] = encoded
	}
	if names := boundaryNames(device.Boundaries); len(names) > 0 {
		metadata["boundary_names"] = strings.Join(names, ",")
	}
	if riskLevel := device.effectiveRiskLevel(); riskLevel > 0 {
		metadata["risk_score"] = strconv.Itoa(riskLevel)
	}
	if queryLabel != "" {
		metadata["query_label"] = queryLabel
	}
	if len(device.Tags) > 0 {
		metadata["source_tags"] = strings.Join(device.Tags, ",")
	}
	if len(device.IPv4Addresses) > 0 {
		metadata["ipv4_addresses"] = strings.Join(device.IPv4Addresses, ",")
	}
	if len(device.IPv6Addresses) > 0 {
		metadata["ipv6_addresses"] = strings.Join(device.IPv6Addresses, ",")
	}
	if len(device.MacAddresses) > 0 {
		metadata["mac_addresses"] = strings.Join(device.MacAddresses, ",")
	}
	if len(device.SerialNumbers) > 0 {
		metadata["serial_number"] = device.SerialNumbers[0]
		metadata["serial_numbers"] = strings.Join(device.SerialNumbers, ",")
	}
	if device.PurdueLevel != nil {
		purdueLevel := strconv.FormatFloat(*device.PurdueLevel, 'f', -1, 64)
		metadata["purdue_level"] = purdueLevel
	}
	if device.Visibility != "" {
		metadata["visibility"] = device.Visibility
	}
	if encoded := compactJSONValue(device.Site); encoded != "" {
		metadata["site"] = encoded
	}
	if encoded := compactJSONValue(device.NetworkInterfaces); encoded != "" {
		metadata["network_interfaces"] = encoded
	}

	return metadata
}

func addArmisTopLevelFields(update map[string]interface{}, device armisDevice) {
	if macAddress := device.primaryMAC(); macAddress != "" {
		update["mac"] = macAddress
	}
	if hostname := device.primaryName(); hostname != "" {
		update["hostname"] = hostname
	}
	if device.Type != "" {
		update["type"] = device.Type
	}
	if brand := firstNonEmpty(device.Brand, device.Manufacturer); brand != "" {
		update["vendor_name"] = brand
	}
	if device.Model != "" {
		update["model"] = device.Model
	}
	if osName := firstNonEmpty(device.OSName, device.OperatingSystem); osName != "" {
		update["os"] = map[string]interface{}{
			"name":    osName,
			"version": device.OSVersion,
		}
	}
	if len(device.NetworkInterfaces) > 0 {
		update["network_interfaces"] = device.NetworkInterfaces
	}
	if firstSeen := device.effectiveFirstSeen(); !firstSeen.IsZero() {
		update["first_seen_time"] = firstSeen.UTC().Format(time.RFC3339Nano)
	}
	if lastSeen := device.effectiveLastSeen(); !lastSeen.IsZero() {
		update["last_seen_time"] = lastSeen.UTC().Format(time.RFC3339Nano)
	}
	if riskLevel := device.effectiveRiskLevel(); riskLevel > 0 {
		update["risk_score"] = riskLevel
	}
}

func (d armisDevice) effectiveID() int {
	if d.DeviceID > 0 {
		return d.DeviceID
	}
	return d.ID
}

func (d armisDevice) effectiveRiskLevel() int {
	if d.RiskLevelSnake > 0 {
		return d.RiskLevelSnake
	}
	return d.RiskLevel
}

func (d armisDevice) effectiveFirstSeen() time.Time {
	if !d.FirstSeenSnake.IsZero() {
		return d.FirstSeenSnake
	}
	return d.FirstSeen
}

func (d armisDevice) effectiveLastSeen() time.Time {
	if !d.LastSeenSnake.IsZero() {
		return d.LastSeenSnake
	}
	return d.LastSeen
}

func (d armisDevice) primaryIP() string {
	if value := strings.TrimSpace(d.IPAddress); value != "" {
		return value
	}
	for _, value := range d.IPv4Addresses {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	for _, value := range d.IPv6Addresses {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

func (d armisDevice) primaryMAC() string {
	if value := strings.TrimSpace(d.MacAddress); value != "" {
		return value
	}
	for _, value := range d.MacAddresses {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

func (d armisDevice) primaryName() string {
	if value := firstNonEmpty(d.Display, d.Name); value != "" {
		return value
	}
	for _, value := range d.Names {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

func boundaryNames(value interface{}) []string {
	if value == nil {
		return nil
	}

	if text, ok := value.(string); ok {
		var decoded interface{}
		if err := json.Unmarshal([]byte(text), &decoded); err == nil {
			return boundaryNames(decoded)
		}
		return nil
	}

	var names []string
	switch typed := value.(type) {
	case []interface{}:
		for _, item := range typed {
			names = append(names, boundaryNames(item)...)
		}
	case []map[string]interface{}:
		for _, item := range typed {
			names = append(names, boundaryNames(item)...)
		}
	case map[string]interface{}:
		if name, ok := typed["name"].(string); ok && strings.TrimSpace(name) != "" {
			names = append(names, strings.TrimSpace(name))
		}
	}

	return uniqueStrings(names)
}

func sortedMapKeys(value map[string]interface{}) []string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func uniqueStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}

	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func compactJSONValue(value interface{}) string {
	if value == nil {
		return ""
	}
	if text, ok := value.(string); ok {
		return strings.TrimSpace(text)
	}
	data, err := json.Marshal(value)
	if err != nil || string(data) == "null" || string(data) == "{}" || string(data) == "[]" {
		return ""
	}
	return string(data)
}

type syncChunkMeta struct {
	syncServiceID string
	runID         string
	totalDevices  int
}

func buildSyncResultsChunks(updates []map[string]interface{}, source models.SourceConfig, runID string) ([]*proto.ResultsChunk, error) {
	if len(updates) == 0 {
		return nil, nil
	}

	meta := syncChunkMeta{
		syncServiceID: source.SyncServiceID,
		runID:         runID,
		totalDevices:  len(updates),
	}

	maxChunkSize, maxHosts := sweepResultsChunkLimits()
	chunkRanges, err := splitSyncUpdates(updates, maxChunkSize, maxHosts, meta)
	if err != nil {
		return nil, err
	}

	totalChunks := len(chunkRanges)
	chunks := make([]*proto.ResultsChunk, 0, totalChunks)

	for idx, chunk := range chunkRanges {
		isFinal := idx == totalChunks-1
		applySyncMeta(chunk, meta, idx, totalChunks, isFinal)

		payload, err := json.Marshal(chunk)
		if err != nil {
			return nil, fmt.Errorf("marshal sync chunk %d: %w", idx, err)
		}

		chunks = append(chunks, &proto.ResultsChunk{
			Data:            payload,
			IsFinal:         isFinal,
			ChunkIndex:      int32(idx),
			TotalChunks:     int32(totalChunks),
			CurrentSequence: runID,
			Timestamp:       time.Now().Unix(),
		})
	}

	return chunks, nil
}

func splitSyncUpdates(
	updates []map[string]interface{},
	maxChunkSize int,
	maxHosts int,
	meta syncChunkMeta,
) ([][]map[string]interface{}, error) {
	if len(updates) == 0 {
		return nil, nil
	}

	chunks := make([][]map[string]interface{}, 0)
	current := make([]map[string]interface{}, 0, maxHosts)
	currentSize := 2

	for _, update := range updates {
		if update == nil {
			continue
		}

		placeholder := buildSyncMeta(meta, 0, 0, false)
		update[syncMetaKey] = placeholder

		encoded, err := json.Marshal(update)
		if err != nil {
			return nil, fmt.Errorf("marshal sync update: %w", err)
		}

		entrySize := len(encoded)
		if len(current) > 0 {
			entrySize++
		}

		if (currentSize+entrySize > maxChunkSize || len(current) >= maxHosts) && len(current) > 0 {
			chunks = append(chunks, current)
			current = make([]map[string]interface{}, 0, maxHosts)
			currentSize = 2
		}

		current = append(current, update)
		currentSize += entrySize
	}

	if len(current) > 0 {
		chunks = append(chunks, current)
	}

	return chunks, nil
}

func applySyncMeta(
	updates []map[string]interface{},
	meta syncChunkMeta,
	chunkIndex int,
	totalChunks int,
	isFinal bool,
) {
	for _, update := range updates {
		if update == nil {
			continue
		}
		update[syncMetaKey] = buildSyncMeta(meta, chunkIndex, totalChunks, isFinal)
	}
}

func buildSyncMeta(meta syncChunkMeta, chunkIndex int, totalChunks int, isFinal bool) map[string]interface{} {
	return map[string]interface{}{
		"sync_service_id": meta.syncServiceID,
		"sync_run_id":     meta.runID,
		"chunk_index":     chunkIndex,
		"total_chunks":    totalChunks,
		"total_devices":   meta.totalDevices,
		"is_final":        isFinal,
	}
}
